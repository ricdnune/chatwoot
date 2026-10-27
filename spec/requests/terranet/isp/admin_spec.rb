require 'rails_helper'

RSpec.describe 'Super Admin > Terranet ISP', type: :request do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:super_admin) { create(:super_admin) }
  let(:secret) { Terranet::IspHelpers::FAKE_SECRET }
  let(:base) { "/super_admin/terranet_isp/accounts/#{account.id}" }
  let(:other_base) { "/super_admin/terranet_isp/accounts/#{other_account.id}" }
  let(:pages) { ['', '/providers/wisphub', '/providers/smartolt', '/identity', '/audit'] }

  def store_secret(for_account, provider = 'wisphub')
    Terranet::Isp::ProviderCredential.fetch_for(for_account, provider).tap do |credential|
      credential.update!(subdomain: 'demo', environment: 'production') if provider == 'smartolt'
      credential.replace_secret!(secret, actor: super_admin)
    end
  end

  describe 'authorization matrix' do
    let(:agent) { create(:user, account: account, role: :agent) }
    let(:account_admin) { create(:user, account: account, role: :administrator) }

    it 'redirects every page and write to the Super Admin sign-in when there is no session' do
      pages.each do |page|
        get "#{base}#{page}"
        expect(response).to redirect_to('/super_admin/sign_in'), page
      end
      patch "#{base}/providers/wisphub/secret", params: { credential: { secret: secret } }
      expect(response).to redirect_to('/super_admin/sign_in')
      expect(Terranet::Isp::ProviderCredential.count).to eq(0)
    end

    it 'does not let agents or account administrators in, and a failed write stores nothing' do
      [agent, account_admin].each do |user|
        attempts = pages.map { |page| [:get, "#{base}#{page}", {}] } + [
          [:patch, "#{base}/providers/wisphub/secret", { credential: { secret: secret } }],
          [:patch, "#{base}/providers/wisphub", { credential: { environment: 'production' } }],
          [:post, "#{base}/providers/wisphub/test", {}],
          [:post, "#{base}/identity/1/decision", { decision: 'confirm', reason: 'other' }]
        ]
        attempts.each do |verb, path, params|
          sign_in(user) # one-shot login per request: every attempt carries a valid app session
          public_send(verb, path, params: params)
          expect(response).to redirect_to('/super_admin/sign_in'), "#{user.role} #{verb} #{path}"
        end
      end
      expect([Terranet::Isp::ProviderCredential.count, Terranet::Isp::AuditEvent.count]).to eq([0, 0])
    end

    it 'does not accept a role, account or elevation sent as parameters' do
      sign_in(agent)
      get base, params: { type: 'SuperAdmin', role: 'administrator', super_admin: true }

      expect(response).to redirect_to('/super_admin/sign_in')
      expect(agent.reload.type).to be_nil
    end

    it 'serves every page to a real Super Admin and lists the entry in the sidebar' do
      sign_in(super_admin, scope: :super_admin)
      pages.each do |page|
        get "#{base}#{page}"
        expect(response).to have_http_status(:ok), page
      end
      expect(response.body).to include('Terranet ISP')
      get '/super_admin'
      expect(response.body).to include('/super_admin/terranet_isp')
    end

    it 'redirects the section root to the first account' do
      account
      sign_in(super_admin, scope: :super_admin)
      get '/super_admin/terranet_isp'

      expect(response).to redirect_to("/super_admin/terranet_isp/accounts/#{Account.order(:id).first.id}")
    end
  end

  describe 'account isolation (IDOR)' do
    before { sign_in(super_admin, scope: :super_admin) }

    it 'shows only the credential state of the account in the URL' do
      store_secret(account)

      get "#{base}/providers/wisphub"
      expect(response.body).to include('Stored encrypted')
      get "#{other_base}/providers/wisphub"
      expect(response.body).to include('No credential stored')
    end

    it 'writes a secret only to the account in the URL' do
      patch "#{base}/providers/wisphub/secret", params: { credential: { secret: secret, account_id: other_account.id } }

      expect(Terranet::Isp::ProviderCredential.pluck(:account_id)).to eq([account.id])
    end

    it 'cannot test a connection that exists only in another account' do
      store_secret(account)
      request = stub_isp_mock('wisphub')

      post "#{other_base}/providers/wisphub/test"

      expect(response).to have_http_status(:not_found)
      expect(request).not_to have_been_requested
    end

    it 'cannot decide on a binding of another account' do
      binding_record = create(:contact, account: account).then do |contact|
        Terranet::Isp::Binding.create!(account_id: account.id, contact_id: contact.id, wisphub_service_id: 'DEMO-1', matched_by: 'sn_onu')
      end

      post "#{other_base}/identity/#{binding_record.id}/decision", params: { decision: 'confirm', reason: 'other' }

      expect(response).to have_http_status(:not_found)
      expect(binding_record.reload.status).to eq('candidate')
    end

    it 'lists only the audit events and contacts of the account in the URL' do
      Terranet::Isp::AuditEvent.record!(account: account, actor: super_admin, action: 'provider.secret_set', outcome: 'success')
      Terranet::Isp::AuditEvent.record!(account: other_account, actor: super_admin, action: 'provider.secret_rotated', outcome: 'success')

      get "#{base}/audit"
      expect(response.body).to include('provider.secret_set')
      expect(response.body).not_to include('provider.secret_rotated')
    end

    it 'does not route a non-numeric account id' do
      get '/super_admin/terranet_isp/accounts/abc'

      expect(response).to have_http_status(:not_found)
    end

    it 'returns 404 for an account that does not exist' do
      get '/super_admin/terranet_isp/accounts/0/identity'

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'credential handling' do
    before { sign_in(super_admin, scope: :super_admin) }

    it 'stores the secret encrypted, never renders it back and audits without it' do
      patch "#{base}/providers/wisphub/secret", params: { credential: { secret: secret } }
      expect(response).to redirect_to("#{base}/providers/wisphub")
      follow_redirect!

      expect(response.body).not_to include(secret)
      expect(response.body).to include('Stored encrypted')
      expect(response.body).not_to match(/name="credential\[secret\]"[^>]*value=/)
      expect(Terranet::Isp::ProviderCredential.last.secret_before_type_cast).not_to include(secret)
      expect(Terranet::Isp::AuditEvent.last).to have_attributes(action: 'provider.secret_set', outcome: 'success')
      expect(Terranet::Isp::AuditEvent.pluck(:metadata).to_json).not_to include(secret)
    end

    it 'keeps the secret out of every other page and out of the request log' do
      log_file = Rails.root.join('log/test.log')
      offset = log_file.size
      patch "#{base}/providers/wisphub/secret", params: { credential: { secret: secret } }
      (pages + ['/providers/smartolt']).each do |page|
        get "#{base}#{page}"
        expect(response.body).not_to include(secret)
      end
      stub_isp_mock('wisphub')
      post "#{base}/providers/wisphub/test"
      follow_redirect!
      written = log_file.open { |file| file.seek(offset) && file.read }

      expect(written).to include('Parameters:').and include('"secret" => "[FILTERED]"')
      expect(written).not_to include(secret)
    end

    it 'logs the rotation as a different action and requires a new value' do
      store_secret(account)
      patch "#{base}/providers/wisphub/secret", params: { credential: { secret: 'mock-ok-fake-credential-0002' } }

      expect(Terranet::Isp::AuditEvent.last.action).to eq('provider.secret_rotated')
      expect(Terranet::Isp::ProviderCredential.last.secret_value).to eq('mock-ok-fake-credential-0002')

      patch "#{base}/providers/wisphub/secret", params: { credential: { secret: '' } }
      expect(response).to redirect_to("#{base}/providers/wisphub")
      expect(Terranet::Isp::ProviderCredential.last.secret_value).to eq('mock-ok-fake-credential-0002')
      expect(Terranet::Isp::AuditEvent.last).to have_attributes(outcome: 'failure')
    end

    it 'fails closed without encryption keys: nothing stored, form disabled, clear message' do
      allow(Chatwoot).to receive(:encryption_configured?).and_return(false)

      get "#{base}/providers/wisphub"
      expect(response.body).to include('Encryption keys are missing')
      patch "#{base}/providers/wisphub/secret", params: { credential: { secret: secret } }
      follow_redirect!

      expect(response.body).to include('Nothing was stored')
      expect(Terranet::Isp::ProviderCredential.count).to eq(0)
      expect(Terranet::Isp::AuditEvent.last).to have_attributes(outcome: 'failure')
    end

    it 'rejects SSRF-style SmartOLT subdomains and never builds a URL from them' do
      ['evil.com', '169.254.169.254', 'a/b', 'u@h', 'x:80'].each do |bad|
        patch "#{base}/providers/smartolt", params: { credential: { subdomain: bad } }
        expect(response).to have_http_status(:unprocessable_entity), bad
      end
      expect(Terranet::Isp::ProviderCredential.count).to eq(0)

      patch "#{base}/providers/smartolt", params: { credential: { subdomain: 'demo-isp' } }
      expect(Terranet::Isp::ProviderCredential.last.subdomain).to eq('demo-isp')
    end

    it 'ignores unpermitted attributes such as status or a forged secret on the settings form' do
      patch "#{base}/providers/wisphub", params: { credential: { environment: 'production', status: 'connected', secret: secret, rotated_by_id: 1 } }

      expect(Terranet::Isp::ProviderCredential.last).to have_attributes(environment: 'production', status: 'not_configured')
      expect(Terranet::Isp::ProviderCredential.last).not_to be_secret_configured
    end

    it 'runs the connection test against the mock and shows the result without secrets' do
      store_secret(account, 'smartolt')
      stub_isp_mock('smartolt', with: { headers: { 'X-Token' => secret } })

      post "#{base}/providers/smartolt/test"
      follow_redirect!

      expect(response.body).to include('succeeded (simulated)')
      expect(response.body).not_to include(secret)
      expect(Terranet::Isp::ConnectionCheck.last).to have_attributes(ok: true, mode: 'mock')
    end

    it 'shows a failure result for a rate-limited provider without leaking the body' do
      store_secret(account)
      stub_isp_mock('wisphub', status: 429, headers: { 'Retry-After' => '30' }, body: '{"leak":"hunter2"}')

      post "#{base}/providers/wisphub/test"
      follow_redirect!

      expect(response.body).to include('rate_limited')
      expect(response.body).not_to include('hunter2')
    end
  end

  describe 'CSRF' do
    it 'rejects state-changing requests without a valid authenticity token' do
      sign_in(super_admin, scope: :super_admin)
      original = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      begin
        patch "#{base}/providers/wisphub/secret", params: { credential: { secret: secret } }
      ensure
        ActionController::Base.allow_forgery_protection = original
      end

      expect(response).to have_http_status(:unprocessable_entity)
      expect(Terranet::Isp::ProviderCredential.count).to eq(0)
    end
  end

  describe 'identity candidates (synthetic)' do
    before { sign_in(super_admin, scope: :super_admin) }

    let(:contact) { create(:contact, account: account, name: 'Synthetic Subscriber') }
    let!(:candidate) do
      Terranet::Isp::Binding.create!(account_id: account.id, contact_id: contact.id, wisphub_service_id: 'DEMO-1', smartolt_external_id: 'ext-1',
                                     matched_by: 'sn_onu')
    end

    it 'never confirms anything by itself' do
      get "#{base}/identity"

      expect(response.body).to include('Synthetic Subscriber', 'DEMO-1')
      expect(candidate.reload.status).to eq('candidate')
    end

    it 'records a human confirmation with actor, reason and an audit event' do
      post "#{base}/identity/#{candidate.id}/decision", params: { decision: 'confirm', reason: 'verified_with_subscriber' }

      expect(candidate.reload).to have_attributes(status: 'confirmed', decided_by_id: super_admin.id, decision_reason: 'verified_with_subscriber')
      expect(Terranet::Isp::AuditEvent.last).to have_attributes(action: 'binding.confirmed', outcome: 'success')
      expect(Terranet::Isp::AuditEvent.last.metadata).to eq('reason' => 'verified_with_subscriber', 'binding_status' => 'confirmed')
    end

    it 'requires a listed reason and a valid transition' do
      post "#{base}/identity/#{candidate.id}/decision", params: { decision: 'confirm', reason: 'because i said so' }
      post "#{base}/identity/#{candidate.id}/decision", params: { decision: 'revoke', reason: 'other' }
      post "#{base}/identity/#{candidate.id}/decision", params: { decision: 'delete', reason: 'other' }

      expect(candidate.reload.status).to eq('candidate')
      expect(Terranet::Isp::AuditEvent.count).to eq(0)
    end
  end
end

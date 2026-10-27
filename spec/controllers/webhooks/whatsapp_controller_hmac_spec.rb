require 'rails_helper'

# Terranet M2.1 (see docs/terranet/06-whatsapp-hmac-diagnosis.md). Synthetic signatures only; no Meta traffic.
# Signature verification is mandatory for every whatsapp_cloud channel (lib/terranet/whatsapp_signature_policy.rb).
RSpec.describe 'Webhooks::WhatsappController HMAC verification', type: :request do
  let(:channel) { create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false) }
  let(:channel_secret) { 'synthetic-channel-app-secret' }
  let(:global_secret) { 'synthetic-global-app-secret' }
  let(:body) do
    { object: 'whatsapp_business_account',
      entry: [{ changes: [{ value: { metadata: { display_phone_number: channel.phone_number.delete_prefix('+'),
                                                 phone_number_id: channel.provider_config['phone_number_id'] } } }] }] }.to_json
  end
  let(:path) { "/webhooks/whatsapp/#{channel.phone_number}" }

  def signature_for(payload, secret)
    "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, payload)}"
  end

  def post_webhook(payload, signature: nil, env: {})
    headers = { 'CONTENT_TYPE' => 'application/json' }
    headers['X-Hub-Signature-256'] = signature if signature
    with_modified_env(env) { post path, params: payload, headers: headers }
  end

  before do
    InstallationConfig.where(name: 'WHATSAPP_APP_SECRET').delete_all
    GlobalConfig.clear_cache
    allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)
  end

  context 'when the channel stores an app secret' do
    before { channel.update!(provider_config: channel.provider_config.merge('app_secret' => channel_secret)) }

    it 'accepts a valid HMAC-SHA256 over the raw body' do
      post_webhook(body, signature: signature_for(body, channel_secret))

      expect(response).to have_http_status(:success)
      expect(Webhooks::WhatsappEventsJob).to have_received(:perform_later)
    end

    it 'rejects a body modified after signing' do
      post_webhook(body.sub('"entry"', '"entry" '), signature: signature_for(body, channel_secret))

      expect(response).to have_http_status(:unauthorized)
      expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
    end

    it 'rejects a signature made with a different secret' do
      post_webhook(body, signature: signature_for(body, 'another-secret'))

      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects a missing signature' do
      post_webhook(body)

      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects a signature without the sha256= prefix' do
      post_webhook(body, signature: OpenSSL::HMAC.hexdigest('SHA256', channel_secret, body))

      expect(response).to have_http_status(:unauthorized)
    end
  end

  context 'when a manual cloud channel has no per-channel app secret (the case upstream skips)' do
    # The factory adds secret/source keys; strip them to mirror a channel created by Whatsapp::ManualSetupService.
    before do
      channel.update!(
        provider_config: channel.provider_config.except('app_secret', 'app_secret_key', 'api_secret', 'client_secret', 'source')
                                .merge('source' => 'manual_setup_v2')
      )
    end

    it 'rejects an unsigned payload and logs an actionable error when no secret exists anywhere' do
      allow(Rails.logger).to receive(:error)

      post_webhook(body)

      expect(response).to have_http_status(:unauthorized)
      expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
      expect(Rails.logger).to have_received(:error).with(/no Meta app secret configured/)
    end

    it 'rejects an unsigned payload when only the global app secret exists' do
      post_webhook(body, env: { WHATSAPP_APP_SECRET: global_secret })

      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects a forged signature when only the global app secret exists' do
      post_webhook(body, signature: signature_for(body, 'attacker-guess'), env: { WHATSAPP_APP_SECRET: global_secret })

      expect(response).to have_http_status(:unauthorized)
    end

    it 'accepts a payload signed with the global Meta app secret (single Meta app, the Terranet setup)' do
      post_webhook(body, signature: signature_for(body, global_secret), env: { WHATSAPP_APP_SECRET: global_secret })

      expect(response).to have_http_status(:success)
      expect(Webhooks::WhatsappEventsJob).to have_received(:perform_later)
    end

    it 'rejects a body modified after signing with the global secret' do
      post_webhook(body.sub('"entry"', '"entry" '), signature: signature_for(body, global_secret), env: { WHATSAPP_APP_SECRET: global_secret })

      expect(response).to have_http_status(:unauthorized)
    end

    it 'ROLLBACK (lab/staging only): TERRANET_WHATSAPP_REQUIRE_SIGNATURE=false restores the upstream behaviour' do
      post_webhook(body, env: { TERRANET_WHATSAPP_REQUIRE_SIGNATURE: 'false' })

      expect(response).to have_http_status(:success)
    end
  end

  context 'when the channel uses another provider' do
    it 'keeps skipping verification for 360dialog channels (upstream behaviour)' do
      dialog = create(:channel_whatsapp, provider: 'default', sync_templates: false, validate_provider_config: false)

      with_modified_env(WHATSAPP_APP_SECRET: global_secret) do
        post "/webhooks/whatsapp/#{dialog.phone_number}", params: { content: 'hello' }.to_json, headers: { 'CONTENT_TYPE' => 'application/json' }
      end

      expect(response).to have_http_status(:success)
    end
  end

  context 'when the inbox API serializes provider_config' do
    let(:administrator) { create(:user, account: channel.account, role: :administrator) }
    let(:agent) { create(:user, account: channel.account, role: :agent) }
    let(:inbox) { create(:inbox, account: channel.account, channel: channel) }

    before { channel.update!(provider_config: channel.provider_config.merge('app_secret' => channel_secret)) }

    it 'CURRENT: returns the full provider_config (api key and app secret) to administrators' do
      get "/api/v1/accounts/#{channel.account.id}/inboxes/#{inbox.id}", headers: administrator.create_new_auth_token, as: :json

      expect(response.parsed_body['provider_config']).to include('api_key' => 'test_key', 'app_secret' => channel_secret)
    end

    it 'does not return provider_config to agents' do
      create(:inbox_member, user: agent, inbox: inbox)

      get "/api/v1/accounts/#{channel.account.id}/inboxes/#{inbox.id}", headers: agent.create_new_auth_token, as: :json

      expect(response.parsed_body).not_to have_key('provider_config')
    end
  end
end

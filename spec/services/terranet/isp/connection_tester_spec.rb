require 'rails_helper'

RSpec.describe Terranet::Isp::ConnectionTester do
  let(:account) { create(:account) }
  let(:actor) { create(:user) }
  let(:secret) { Terranet::IspHelpers::FAKE_SECRET }
  let(:credential) do
    Terranet::Isp::ProviderCredential.fetch_for(account, 'wisphub').tap { |record| record.replace_secret!(secret, actor: actor) }
  end

  def run = described_class.new(credential: credential, actor: actor, request_id: 'req-1').call

  it 'records a successful simulated check, updates the credential and audits it' do
    stub_isp_mock('wisphub')

    outcome = run

    expect(outcome.ok).to be(true)
    expect(credential.reload).to have_attributes(status: 'connected', last_error_code: nil)
    expect(Terranet::Isp::ConnectionCheck.last).to have_attributes(ok: true, mode: 'mock', http_status: 200, actor_id: actor.id)
    expect(Terranet::Isp::AuditEvent.last).to have_attributes(action: 'provider.connection_tested', outcome: 'success', actor_id: actor.id,
                                                              request_id: 'req-1')
  end

  { 401 => 'unauthorized', 403 => 'forbidden', 404 => 'not_found' }.each do |status, code|
    it "reports #{status} as #{code}, marks the credential as error and audits a failure" do
      stub_isp_mock('wisphub', status: status)

      expect(run.error_code).to eq(code)
      expect(credential.reload).to have_attributes(status: 'error', last_error_code: code)
      expect(Terranet::Isp::AuditEvent.last).to have_attributes(outcome: 'failure')
    end
  end

  it 'honours 429 + Retry-After: stores the cooldown and makes no HTTP call while it lasts' do
    request = stub_isp_mock('wisphub', status: 429, headers: { 'Retry-After' => '45' })

    expect(run.error_code).to eq('rate_limited')
    expect(credential.reload.rate_limited_until).to be_within(5.seconds).of(45.seconds.from_now)

    expect(run.error_code).to eq('rate_limited_locally')
    expect(request).to have_been_requested.once
  end

  it 'refuses without encryption keys or without a secret, and contacts nobody' do
    request = stub_isp_mock('wisphub')
    empty = Terranet::Isp::ProviderCredential.fetch_for(account, 'smartolt').tap { |c| c.update!(subdomain: 'demo', environment: 'production') }

    expect(described_class.new(credential: empty, actor: actor).call.error_code).to eq('no_secret')
    credential
    allow(Chatwoot).to receive(:encryption_configured?).and_return(false)
    expect(run.error_code).to eq('encryption_not_configured')
    expect(request).not_to have_been_requested
  end

  it 'keeps only whitelisted, non-sensitive metadata in the audit trail and the logs' do
    stub_isp_mock('wisphub', status: 500, body: "leak #{secret} password=hunter2")
    allow(Rails.logger).to receive(:warn).and_call_original
    logged = []
    allow(Rails.logger).to receive(:info) { |*args, &block| logged << (args.first || block&.call).to_s }

    run
    event = Terranet::Isp::AuditEvent.last

    expect(event.metadata.keys - Terranet::Isp::AuditEvent::METADATA_KEYS).to be_empty
    expect([event.to_json, Terranet::Isp::ConnectionCheck.last.to_json, logged.join].join).not_to include(secret, 'hunter2', 'leak')
  end

  it 'keeps at most RETENTION checks per credential' do
    stub_isp_mock('wisphub')
    stub_const('Terranet::Isp::ConnectionCheck::RETENTION', 3)

    5.times { run }

    expect(Terranet::Isp::ConnectionCheck.where(credential_id: credential.id).count).to eq(3)
  end

  it 'audit events and checks are append-only' do
    stub_isp_mock('wisphub')
    run

    expect { Terranet::Isp::AuditEvent.last.update!(outcome: 'denied') }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect { Terranet::Isp::AuditEvent.last.destroy }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect { Terranet::Isp::ConnectionCheck.last.update!(ok: false) }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it 'rejects audit metadata outside the whitelist' do
    expect do
      Terranet::Isp::AuditEvent.record!(account: account, actor: actor, action: 'provider.secret_set', outcome: 'success', metadata: { secret: 'x' })
    end.to raise_error(ActiveRecord::RecordInvalid, /whitelist/)
  end
end

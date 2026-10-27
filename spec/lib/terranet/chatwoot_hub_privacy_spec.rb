require 'rails_helper'

# Terranet privacy mode must stop every call that reaches hub.2.chatwoot.com. WebMock (spec_helper) raises on any
# real connection, so an unexpected outbound request fails these examples instead of leaving the machine.
RSpec.describe Terranet::ChatwootHubPrivacy do
  let(:hub_host) { %r{\Ahttps://hub\.2\.chatwoot\.com/} }

  def hub_calls
    [
      -> { ChatwootHub.sync_with_hub },
      -> { ChatwootHub.register_instance('Terranet', 'Owner', 'owner@example.invalid') },
      -> { ChatwootHub.send_push({ to: 'token' }) },
      -> { ChatwootHub.send_push_with_response({ to: 'token' }) },
      -> { ChatwootHub.emit_event('event', { a: 1 }) }
    ]
  end

  context 'when TERRANET_PRIVACY_MODE is enabled' do
    around { |example| with_modified_env(TERRANET_PRIVACY_MODE: 'true', DISABLE_TELEMETRY: nil) { example.run } }

    it 'makes no HTTP request for any ChatwootHub call' do
      expect(RestClient).not_to receive(:post)

      hub_calls.each(&:call)

      expect(WebMock).not_to have_requested(:any, hub_host)
    end

    it 'returns an empty hash from sync_with_hub so the version check job stays a no-op' do
      expect(ChatwootHub.sync_with_hub).to eq({})
    end
  end

  context 'when TERRANET_PRIVACY_MODE is not set (upstream behaviour, mocked network)' do
    around { |example| with_modified_env(TERRANET_PRIVACY_MODE: nil, DISABLE_TELEMETRY: nil) { example.run } }

    it 'still sends usage counters on the daily ping' do
      stub = stub_request(:post, 'https://hub.2.chatwoot.com/ping').to_return(status: 200, body: { version: '9.9.9' }.to_json)

      expect(ChatwootHub.sync_with_hub).to eq({ 'version' => '9.9.9' })
      expect(stub.with { |req| JSON.parse(req.body).key?('accounts_count') }).to have_been_requested
    end

    it 'sends events' do
      stub = stub_request(:post, 'https://hub.2.chatwoot.com/events').to_return(status: 200, body: '{}')

      ChatwootHub.emit_event('sample_event', { sample: true })

      expect(stub).to have_been_requested
    end
  end

  # Documents the residual traffic that DISABLE_TELEMETRY alone leaves (found in M2 audit). If upstream ever
  # stops sending the identifier/version/host on the base ping this example fails and the audit must be redone.
  context 'when only DISABLE_TELEMETRY is set (the residual ping)' do
    around { |example| with_modified_env(TERRANET_PRIVACY_MODE: nil, DISABLE_TELEMETRY: 'true') { example.run } }

    it 'drops counters but still identifies the installation' do
      stub = stub_request(:post, 'https://hub.2.chatwoot.com/ping').to_return(status: 200, body: '{}')

      ChatwootHub.sync_with_hub

      expect(stub.with do |req|
        keys = JSON.parse(req.body).keys
        keys.include?('installation_identifier') && keys.exclude?('accounts_count')
      end).to have_been_requested
    end
  end
end

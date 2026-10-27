# Fake credentials only. The mock server and these specs accept values starting with `mock-`; nothing here is a real token.
module Terranet::IspHelpers
  FAKE_SECRET = 'mock-ok-fake-credential-0001'.freeze
  MOCK_BASE = 'http://isp-mock:4010'.freeze

  def stub_isp_mock(provider, status: 200, body: nil, headers: {}, with: {})
    wisphub = provider == 'wisphub'
    path = wisphub ? "#{MOCK_BASE}/wisphub/api/clientes/" : "#{MOCK_BASE}/smartolt/api/system/get_olts"
    body ||= wisphub ? { count: 1, results: [{ id_servicio: 1 }] }.to_json : { status: true, response: [] }.to_json
    conditions = wisphub ? { query: { limit: 1 } }.merge(with) : with
    stub_request(:get, path).with(**conditions).to_return(status: status, body: body,
                                                          headers: { 'Content-Type' => 'application/json' }.merge(headers))
  end
end

RSpec.configure { |config| config.include Terranet::IspHelpers }

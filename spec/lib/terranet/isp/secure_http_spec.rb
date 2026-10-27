require 'rails_helper'

RSpec.describe Terranet::Isp::SecureHttp do
  subject(:client) { described_class.new(Terranet::Isp::Endpoint.for(provider: 'wisphub', environment: 'sandbox')) }

  let(:url) { 'http://isp-mock:4010/wisphub/api/clientes/' }
  let(:secret) { Terranet::IspHelpers::FAKE_SECRET }
  let(:headers) { { 'Authorization' => "Api-Key #{secret}" } }

  def get = client.get('/clientes/', headers: headers, query: { limit: 1 })

  it 'sends a GET with the auth header and JSON accept, and parses a JSON body' do
    request = stub_request(:get, url).with(query: { limit: 1 }, headers: { 'Authorization' => "Api-Key #{secret}", 'Accept' => 'application/json' })
                                     .to_return(status: 200, body: '{"count":1}', headers: { 'Content-Type' => 'application/json' })

    result = get

    expect(result).to be_ok
    expect(result.json).to eq('count' => 1)
    expect(request).to have_been_requested.once
  end

  { 401 => 'unauthorized', 403 => 'forbidden', 404 => 'not_found', 500 => 'upstream_error', 503 => 'upstream_error',
    418 => 'http_error' }.each do |status, code|
    it "maps HTTP #{status} to #{code}" do
      stub_request(:get, url).with(query: { limit: 1 }).to_return(status: status, body: '{"detail":"x"}',
                                                                  headers: { 'Content-Type' => 'application/json' })

      expect(get.error_code).to eq(code)
    end
  end

  it 'reads Retry-After on 429 (bounded) and defaults when it is missing or hostile' do
    { '30' => 30, '999999' => described_class::MAX_RETRY_AFTER, 'soon' => 60, nil => 60 }.each do |header, expected|
      stub_request(:get, url).with(query: { limit: 1 }).to_return(status: 429, body: '{}', headers: { 'Retry-After' => header }.compact)

      result = get
      expect(result.error_code).to eq('rate_limited')
      expect(result.retry_after).to eq(expected)
    end
  end

  it 'never follows a redirect (even to a metadata address)' do
    stub_request(:get, url).with(query: { limit: 1 }).to_return(status: 302, headers: { 'Location' => 'http://169.254.169.254/latest/meta-data/' })
    metadata = stub_request(:get, /169\.254\.169\.254/)

    expect(get.error_code).to eq('redirect_blocked')
    expect(metadata).not_to have_been_requested
  end

  it 'reports timeouts and connection failures without raising' do
    stub_request(:get, url).with(query: { limit: 1 }).to_timeout
    expect(get.error_code).to eq('timeout')

    stub_request(:get, url).with(query: { limit: 1 }).to_raise(SocketError)
    expect(get.error_code).to eq('connection_failed')
  end

  it 'refuses oversized responses' do
    stub_request(:get, url).with(query: { limit: 1 }).to_return(status: 200, body: "{\"pad\":\"#{'x' * (described_class::MAX_BYTES + 10)}\"}",
                                                                headers: { 'Content-Type' => 'application/json' })

    expect(get.error_code).to eq('response_too_large')
  end

  it 'refuses non-JSON content types and malformed JSON' do
    stub_request(:get, url).with(query: { limit: 1 }).to_return(status: 200, body: '<html></html>', headers: { 'Content-Type' => 'text/html' })
    expect(get.error_code).to eq('invalid_response')

    stub_request(:get, url).with(query: { limit: 1 }).to_return(status: 200, body: '{nope', headers: { 'Content-Type' => 'application/json' })
    expect(get.error_code).to eq('invalid_response')
  end

  it 'never exposes the credential or the body through the result' do
    stub_request(:get, url).with(query: { limit: 1 }).to_return(status: 500, body: "boom #{secret}",
                                                                headers: { 'Content-Type' => 'application/json' })

    expect(get.inspect).not_to include(secret)
    expect(get.inspect).not_to include('boom')
  end

  it 'uses bounded timeouts' do
    expect([described_class::OPEN_TIMEOUT, described_class::READ_TIMEOUT]).to eq([3, 8])
  end
end

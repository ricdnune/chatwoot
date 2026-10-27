require 'rails_helper'

RSpec.describe Terranet::Isp::Endpoint do
  describe 'default mode' do
    it 'is the local mock: the module never goes live unless explicitly enabled' do
      expect(Terranet::Isp.mode).to eq(:mock)
      endpoint = described_class.for(provider: 'wisphub', environment: 'production')

      expect([endpoint.scheme, endpoint.host, endpoint.port, endpoint.base_path]).to eq(['http', 'isp-mock', 4010, '/wisphub/api'])
    end

    it 'accepts only bare local origins for the mock URL' do
      ['http://169.254.169.254', 'https://api.wisphub.net', 'http://user:pw@isp-mock:4010', 'http://isp-mock:4010/x',
       'http://example.com'].each do |bad|
        with_modified_env(TERRANET_ISP_MOCK_URL: bad) do
          expect { described_class.for(provider: 'wisphub', environment: 'sandbox') }.to raise_error(described_class::Invalid), bad
        end
      end
    end
  end

  describe 'live mode' do
    around { |example| with_modified_env(TERRANET_ISP_MODE: 'live') { example.run } }

    it 'builds the WispHub host from the fixed environment enum' do
      expect(described_class.for(provider: 'wisphub', environment: 'sandbox').host).to eq('sandbox-api.wisphub.net')
      expect(described_class.for(provider: 'wisphub', environment: 'production').host).to eq('api.wisphub.net')
      expect { described_class.for(provider: 'wisphub', environment: 'evil.test') }.to raise_error(described_class::Invalid)
    end

    it 'builds SmartOLT only from a valid subdomain, always https:443 under smartolt.com' do
      endpoint = described_class.for(provider: 'smartolt', environment: 'production', subdomain: 'demo-isp')

      expect([endpoint.scheme, endpoint.host, endpoint.port]).to eq(['https', 'demo-isp.smartolt.com', 443])
      ['evil.com/x', 'a.b', '127.0.0.1', 'u@h', ''].each do |bad|
        expect { described_class.for(provider: 'smartolt', environment: 'production', subdomain: bad) }.to raise_error(described_class::Invalid)
      end
    end

    it 'rejects hosts that resolve to private, loopback or link-local addresses (SSRF / DNS rebinding)' do
      %w[127.0.0.1 10.1.2.3 172.16.0.9 192.168.1.1 169.254.169.254 100.64.0.1 ::1 fd00::1].each do |address|
        allow(Resolv).to receive(:getaddresses).and_return([address])
        endpoint = described_class.for(provider: 'wisphub', environment: 'production')

        expect { endpoint.pinned_ip }.to raise_error(described_class::Invalid, /non-public/), address
      end
    end

    it 'rejects a host if ANY resolved address is private and pins the connection to a public one otherwise' do
      endpoint = described_class.for(provider: 'wisphub', environment: 'production')
      allow(Resolv).to receive(:getaddresses).and_return(['203.0.113.10', '10.0.0.1'])
      expect { endpoint.pinned_ip }.to raise_error(described_class::Invalid)

      allow(Resolv).to receive(:getaddresses).and_return(['203.0.113.10'])
      expect(endpoint.pinned_ip).to eq('203.0.113.10')
    end
  end
end

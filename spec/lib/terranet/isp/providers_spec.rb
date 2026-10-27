require 'rails_helper'

RSpec.describe Terranet::Isp::Providers do
  let(:account) { create(:account) }
  let(:actor) { create(:user) }
  let(:secret) { Terranet::IspHelpers::FAKE_SECRET }

  def credential_for(provider, **attrs)
    described_class_credential = Terranet::Isp::ProviderCredential.fetch_for(account, provider)
    described_class_credential.assign_attributes(attrs)
    described_class_credential.replace_secret!(secret, actor: actor)
    described_class_credential
  end

  describe 'WispHub' do
    it 'authenticates with Authorization: Api-Key and lists a single client' do
      request = stub_isp_mock('wisphub', with: { query: { limit: 1 }, headers: { 'Authorization' => "Api-Key #{secret}" } })

      expect(described_class.for(credential_for('wisphub')).check_connection).to be_ok
      expect(request).to have_been_requested
    end

    it 'normalizes through a whitelist and drops every password-like and personal field' do
      raw = { 'id_servicio' => 77, 'estado' => 'Activo', 'plan_internet' => { 'nombre' => 'Plan Demo' }, 'zona' => 'Z1', 'sn_onu' => 'DEMO01',
              'password_servicio' => 'a', 'password_cpe' => 'b', 'password_router_wifi' => 'c', 'password_ssid_router_wifi' => 'd',
              'usuario_router_wifi' => 'e', 'cedula' => '0000000000', 'telefono' => '+593000000000', 'direccion' => 'x',
              'email' => 'x@example.invalid' }

      service = Terranet::Isp::Providers::Wisphub.normalize_service(raw)

      expect(service.to_h).to eq(service_id: '77', status: 'Activo', plan: 'Plan Demo', zone: 'Z1', onu_serial: 'DEMO01')
      expect(service.to_h.values.join).not_to match(/password|0000000000|\+593|example\.invalid/)
    end

    it 'turns unexpected shapes into nil instead of keeping raw structures' do
      service = Terranet::Isp::Providers::Wisphub.normalize_service('id_servicio' => [1, 2], 'estado' => { 'x' => 1 }, 'plan_internet' => 5)

      expect(service.to_h.values.compact).to eq(['5'])
    end
  end

  describe 'SmartOLT' do
    it 'authenticates with X-Token against the structural subdomain endpoint (mock mode)' do
      request = stub_isp_mock('smartolt', with: { headers: { 'X-Token' => secret } })
      credential = credential_for('smartolt', subdomain: 'demo-isp', environment: 'production')

      expect(described_class.for(credential).check_connection).to be_ok
      expect(request).to have_been_requested
    end

    it 'targets https://<subdomain>.smartolt.com in live mode, with a DNS-pinned public address' do
      credential = credential_for('smartolt', subdomain: 'demo-isp', environment: 'production')
      allow(Resolv).to receive(:getaddresses).with('demo-isp.smartolt.com').and_return(['203.0.113.7'])
      request = stub_request(:get, 'https://demo-isp.smartolt.com/api/system/get_olts')
                .with(headers: { 'X-Token' => secret })
                .to_return(status: 200, body: '{"status":true}', headers: { 'Content-Type' => 'application/json' })

      with_modified_env(TERRANET_ISP_MODE: 'live') { expect(described_class.for(credential).check_connection).to be_ok }
      expect(request).to have_been_requested
    end

    it 'drops username/password and every non-whitelisted ONU field' do
      raw = { 'unique_external_id' => 'ext-1', 'sn' => 'DEMO01', 'status' => 'Online', 'olt_id' => 3, 'zone_name' => 'Z',
              'username' => 'u', 'password' => 'p',
              'wan_ip' => '10.0.0.5', 'mgmt_ip' => '10.0.0.6', 'onu_external_id' => 'x' }

      onu = Terranet::Isp::Providers::Smartolt.normalize_onu(raw)

      expect(onu.to_h).to eq(external_id: 'ext-1', serial: 'DEMO01', status: 'Online', olt_id: '3', zone: 'Z')
    end
  end
end

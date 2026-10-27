require 'rails_helper'

RSpec.describe 'Installation::Onboarding with Terranet privacy mode', type: :request do
  before { Redis::Alfred.set(Redis::Alfred::CHATWOOT_INSTALLATION_ONBOARDING, true) }

  after { Redis::Alfred.delete(Redis::Alfred::CHATWOOT_INSTALLATION_ONBOARDING) }

  it 'offers the "subscribe to updates" checkbox (pre-checked) upstream' do
    with_modified_env(TERRANET_PRIVACY_MODE: nil) do
      get '/installation/onboarding'

      expect(response.body).to include('subscribe_to_updates')
    end
  end

  it 'hides the checkbox in privacy mode' do
    with_modified_env(TERRANET_PRIVACY_MODE: 'true') do
      get '/installation/onboarding'

      expect(response).to have_http_status(:success)
      expect(response.body).not_to include('subscribe_to_updates')
    end
  end

  it 'sends no owner data to Chatwoot even if the parameter is forced in privacy mode' do
    with_modified_env(TERRANET_PRIVACY_MODE: 'true') do
      allow(AccountBuilder).to receive(:new).and_return(instance_double(AccountBuilder, perform: true))
      expect(RestClient).not_to receive(:post)

      post '/installation/onboarding',
           params: { subscribe_to_updates: 'true',
                     user: { name: 'Owner', company: 'Terranet', email: 'owner@example.invalid', password: 'Password1!' } }

      expect(WebMock).not_to have_requested(:any, /chatwoot\.com/)
    end
  end
end

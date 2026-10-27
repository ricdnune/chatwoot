require 'rails_helper'

RSpec.describe Avatar::AvatarFromFaviconJob do
  let(:company) { create(:company, domain: 'private-customer.example') }

  it 'does not send the company domain to Google in privacy mode' do
    with_modified_env(TERRANET_PRIVACY_MODE: 'true') do
      expect(Avatar::AvatarFromUrlJob).not_to receive(:perform_now)

      described_class.perform_now(company)

      expect(WebMock).not_to have_requested(:any, /google\.com/)
    end
  end

  it 'fetches the favicon from Google when privacy mode is off (upstream behaviour, mocked)' do
    with_modified_env(TERRANET_PRIVACY_MODE: nil) do
      expect(Avatar::AvatarFromUrlJob).to receive(:perform_now).with(company, %r{\Ahttps://www\.google\.com/s2/favicons})

      described_class.perform_now(company)
    end
  end
end

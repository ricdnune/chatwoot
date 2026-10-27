require 'rails_helper'

RSpec.describe Notification::PushNotificationService do
  let!(:account) { create(:account) }
  let!(:user) { create(:user, account: account) }
  let!(:notification) { create(:notification, user: user, account: account) }

  before { create(:notification_subscription, user: user, subscription_type: 'fcm') }

  it 'does not use the Chatwoot push relay when ENABLE_PUSH_RELAY_SERVER=false' do
    with_modified_env(ENABLE_PUSH_RELAY_SERVER: 'false', TERRANET_PRIVACY_MODE: nil) do
      expect(ChatwootHub).not_to receive(:send_push)

      described_class.new(notification: notification).perform
    end
  end

  it 'reaches the relay method but sends nothing over HTTP in privacy mode even if the relay flag is left on' do
    with_modified_env(ENABLE_PUSH_RELAY_SERVER: 'true', TERRANET_PRIVACY_MODE: 'true') do
      expect(RestClient).not_to receive(:post)

      described_class.new(notification: notification).perform

      expect(WebMock).not_to have_requested(:any, /chatwoot\.com/)
    end
  end
end

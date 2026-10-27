require 'rails_helper'

# Simulates the production path (the version check only runs when Rails.env.production?) with the network blocked.
RSpec.describe Internal::CheckNewVersionsJob do
  around { |example| with_modified_env(TERRANET_PRIVACY_MODE: 'true', DISABLE_TELEMETRY: nil) { example.run } }

  before { allow(Rails.env).to receive(:production?).and_return(true) }

  it 'runs Internal::CheckNewVersionsJob without any outbound request and without touching the latest-version key' do
    expect(RestClient).not_to receive(:post)
    expect(Redis::Alfred).not_to receive(:set).with(Redis::Alfred::LATEST_CHATWOOT_VERSION, anything)

    expect { described_class.perform_now }.not_to raise_error
    expect(WebMock).not_to have_requested(:any, /chatwoot\.com/)
  end

  it 'runs the whole daily trigger -> scheduled check chain without outbound requests' do
    expect(RestClient).not_to receive(:post)

    perform_enqueued_jobs do
      Internal::TriggerDailyScheduledItemsJob.perform_now
    end

    expect(WebMock).not_to have_requested(:any, /chatwoot\.com/)
  end
end

require 'rails_helper'

RSpec.describe Avatar::AvatarFromGravatarJob do
  let(:user) { create(:user) }

  it 'does not look up Gravatar when DISABLE_GRAVATAR is set' do
    with_modified_env(DISABLE_GRAVATAR: '1') do
      GlobalConfig.clear_cache
      expect(Avatar::AvatarFromUrlJob).not_to receive(:perform_later)

      described_class.perform_now(user, 'someone@example.invalid')
    end
  ensure
    GlobalConfig.clear_cache
  end

  it 'queues the Gravatar download by default' do
    with_modified_env(DISABLE_GRAVATAR: nil) do
      GlobalConfig.clear_cache
      expect(Avatar::AvatarFromUrlJob).to receive(:perform_later).with(user, %r{\Ahttps://www\.gravatar\.com/avatar/})

      described_class.perform_now(user, 'someone@example.invalid')
    end
  end
end

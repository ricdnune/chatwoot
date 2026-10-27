# Terranet privacy mode: when TERRANET_PRIVACY_MODE is truthy this installation never contacts
# Chatwoot-operated services (install/usage/update checks, instance registration, push relay) and
# never sends contact data to third-party avatar services. Off by default so upstream behaviour is unchanged.
module Terranet::Privacy
  def self.enabled?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch('TERRANET_PRIVACY_MODE', false))
  end
end

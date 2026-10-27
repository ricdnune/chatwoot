# Terranet WhatsApp Cloud hardening (M2.1). Secure by default: Meta webhook signatures (HMAC-SHA256) are mandatory for every
# whatsapp_cloud channel. TERRANET_WHATSAPP_REQUIRE_SIGNATURE=false is a rollback switch for the lab/staging only.
module Terranet::Whatsapp
  def self.signature_required?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch('TERRANET_WHATSAPP_REQUIRE_SIGNATURE', true))
  end
end

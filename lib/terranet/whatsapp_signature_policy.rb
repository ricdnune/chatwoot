# Prepended to Webhooks::WhatsappController (config/initializers/terranet_whatsapp_signature.rb).
# Upstream skips verification for a whatsapp_cloud channel that has no per-channel app secret and is not embedded_signup
# (e.g. channels created by Whatsapp::ManualSetupService), so unsigned and forged payloads were accepted. Here:
#  - every whatsapp_cloud channel requires a valid X-Hub-Signature-256 over the raw body (constant-time compare, upstream code);
#  - no usable secret (channel app_secret or WHATSAPP_APP_SECRET) => reject with an actionable log line, never fall back to accepting;
#  - 360dialog and other providers keep their upstream behaviour.
module Terranet::WhatsappSignaturePolicy
  private

  def meta_signature_verification_required?
    return super unless Terranet::Whatsapp.signature_required?
    return true if whatsapp_channel.blank?

    whatsapp_channel.provider == 'whatsapp_cloud'
  end

  def verify_meta_signature!
    if meta_signature_verification_required? && meta_app_secrets.all?(&:blank?)
      Rails.logger.error("Terranet: rejected WhatsApp webhook for channel #{whatsapp_channel&.id.inspect}: no Meta app secret configured " \
                         '(set WHATSAPP_APP_SECRET or the channel app_secret)')
      return head :unauthorized
    end

    super
  end
end

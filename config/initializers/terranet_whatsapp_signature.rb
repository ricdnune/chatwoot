# Applied in to_prepare so the prepend survives code reloading in development.
Rails.application.config.to_prepare do
  Webhooks::WhatsappController.prepend(Terranet::WhatsappSignaturePolicy)
end

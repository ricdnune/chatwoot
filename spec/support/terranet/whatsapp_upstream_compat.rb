# Upstream's example "skips signature validation for manual whatsapp cloud channels without an app secret"
# (spec/controllers/webhooks/whatsapp_controller_spec.rb) asserts the insecure behaviour that Terranet removes in M2.1.
# It is not edited or deleted: it runs in upstream-compat mode (rollback switch on) so it keeps guarding that code path,
# while spec/controllers/webhooks/whatsapp_controller_hmac_spec.rb covers the hardened behaviour.
RSpec.configure do |config|
  config.around do |example|
    upstream_skip = example.metadata[:file_path].to_s.end_with?('webhooks/whatsapp_controller_spec.rb') &&
                    example.description.start_with?('skips signature validation for manual whatsapp cloud channels')

    if upstream_skip
      with_modified_env(TERRANET_WHATSAPP_REQUIRE_SIGNATURE: 'false') { example.run }
    else
      example.run
    end
  end
end

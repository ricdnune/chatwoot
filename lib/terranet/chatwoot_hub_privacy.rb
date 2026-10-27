# Prepended to ChatwootHub's singleton (see the last lines of lib/chatwoot_hub.rb). Every call that reaches
# hub.2.chatwoot.com goes through one of these four methods, so privacy mode short-circuits them before any HTTP.
module Terranet::ChatwootHubPrivacy
  # CheckNewVersionsJob reads ['version'] from the result, so an empty hash keeps that job a harmless no-op.
  def sync_with_hub
    return {} if Terranet::Privacy.enabled?

    super
  end

  def register_instance(...)
    return if Terranet::Privacy.enabled?

    super
  end

  def send_push_with_response(...)
    return if Terranet::Privacy.enabled?

    super
  end

  def emit_event(...)
    return if Terranet::Privacy.enabled?

    super
  end
end

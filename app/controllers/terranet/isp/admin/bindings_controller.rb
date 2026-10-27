class Terranet::Isp::Admin::BindingsController < Terranet::Isp::Admin::BaseController
  DECISIONS = { 'confirm' => 'confirmed', 'reject' => 'rejected', 'revoke' => 'revoked' }.freeze

  def index
    @bindings = Terranet::Isp::Binding.for_account(@account).ordered
    @contacts = Contact.where(account_id: @account.id, id: @bindings.map(&:contact_id)).index_by(&:id)
  end

  def decide
    binding_record = Terranet::Isp::Binding.for_account(@account).find(params[:id])
    status = DECISIONS[params[:decision]]
    reason = params[:reason].to_s
    return reject_decision unless status && reason.in?(Terranet::Isp::Binding::REASONS)

    begin
      binding_record.decide!(status: status, reason: reason, actor: current_super_admin)
    rescue ArgumentError
      return reject_decision
    end
    audit!("binding.#{status}", 'success', subject: binding_record, metadata: { reason: reason, binding_status: status })
    redirect_to super_admin_terranet_isp_bindings_path(account_id: @account.id), notice: t('terranet_isp.flash.decision_saved')
  end

  private

  def reject_decision
    redirect_to super_admin_terranet_isp_bindings_path(account_id: @account.id), alert: t('terranet_isp.flash.decision_invalid')
  end
end

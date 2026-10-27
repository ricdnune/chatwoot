# Adds the "Terranet ISP" entry to the Super Admin sidebar without editing the upstream helper (prepended in the initializer).
module Terranet::Isp::NavigationExtension
  def primary_nav_items
    items = super
    entry = { label: t('terranet_isp.nav.label'), url: super_admin_terranet_isp_root_path, icon: 'i-lucide-network',
              active: controller_path.start_with?('terranet/isp/'), group: t('super_admin.navigation.groups.manage') }
    items.insert(items.index { |item| item[:url] == super_admin_settings_path } || items.length, entry)
  end
end

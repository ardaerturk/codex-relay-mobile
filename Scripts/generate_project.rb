require 'xcodeproj'
root = File.expand_path('..', __dir__)
project = Xcodeproj::Project.new(File.join(root, 'Relay.xcodeproj'))
target = project.new_target(:application, 'Relay', :ios, '18.0')
group = project.main_group.new_group('Relay', 'Relay')
Dir.glob(File.join(root, 'Relay', '**', '*.swift')).sort.each do |path|
  file = group.new_file(path.delete_prefix(File.join(root, 'Relay') + '/'))
  target.source_build_phase.add_file_reference(file)
end
privacy = group.new_file('PrivacyInfo.xcprivacy')
target.resources_build_phase.add_file_reference(privacy)
if Dir.exist?(File.join(root,'Relay','Assets.xcassets'))
  target.resources_build_phase.add_file_reference(group.new_file('Assets.xcassets'))
end
target.build_configurations.each do |c|
  c.build_settings.merge!({
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.example.codexrelay',
    'SWIFT_VERSION' => '5.0', 'IPHONEOS_DEPLOYMENT_TARGET' => '18.0',
    'TARGETED_DEVICE_FAMILY' => '1,2', 'INFOPLIST_FILE' => 'Relay/Info.plist',
    'MARKETING_VERSION' => '0.1.0', 'CURRENT_PROJECT_VERSION' => '1',
    'CODE_SIGN_STYLE' => 'Automatic', 'ASSETCATALOG_COMPILER_APPICON_NAME' => 'AppIcon',
    'ENABLE_USER_SCRIPT_SANDBOXING' => 'YES', 'SUPPORTS_MACCATALYST' => 'NO',
    'GENERATE_INFOPLIST_FILE' => 'NO', 'SWIFT_EMIT_LOC_STRINGS' => 'YES'
  })
end
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.set_launch_target(target)
scheme.save_as(File.join(root,'Relay.xcodeproj'), 'Relay', true)
project.save
puts 'Generated Relay.xcodeproj'

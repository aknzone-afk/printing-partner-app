Pod::Spec.new do |s|
  s.name             = 'bb_native_codec'
  s.version          = '0.0.1'
  s.summary          = 'Native iOS JPEG codec (ImageIO/CoreGraphics) for PrintCollageTool.'
  s.description      = 'Decode, encode, and fit-transcode JPEGs at native speed on iOS.'
  s.homepage         = 'https://bbprints.local'
  s.license          = { :type => 'MIT', :text => 'MIT License. Copyright (c) Printing Partner.' }
  s.author           = { 'BB Prints' => 'noreply@bbprints.local' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'SWIFT_VERSION' => '5.0' }
  s.swift_version = '5.0'
end

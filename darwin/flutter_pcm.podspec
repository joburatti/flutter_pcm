Pod::Spec.new do |s|
  s.name             = 'flutter_pcm'
  s.version          = '0.0.1'
  s.summary          = 'PCM Audio Player'
  s.description      = 'PCM Audio Player'
  s.homepage         = 'http://none'
  s.license          = { :type => 'LGPL' }
  s.author           = { 'Johan Buratti' => 'johan@johanburatti.se' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'

  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'

  s.ios.deployment_target = '12.0'
  s.osx.deployment_target = '10.11'

  s.framework = 'CoreAudio'
  
  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
end

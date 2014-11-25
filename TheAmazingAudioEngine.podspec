Pod::Spec.new do |s|
  s.name         = "TheAmazingAudioEngine"
  s.version      = "1.4.5"
  s.summary      = "Core Audio, Cordially: A sophisticated framework for iOS audio applications, built so you don't have to."
  s.homepage     = "http://theamazingaudioengine.com"
  s.license      = 'zlib'
  s.author       = { "Michael Tyson" => "michael@atastypixel.com" }
  s.source       = { :git => "https://github.com/TheAmazingAudioEngine/TheAmazingAudioEngine.git", :tag => "1.4.5" }
  s.platform     = :ios, '6.0'
  s.source_files = 'TheAmazingAudioEngine/**/*.{h,m,c}', 'Modules/*.{h,m,c}'
  s.frameworks = 'AudioToolbox', 'Accelerate'
  s.requires_arc = true
end

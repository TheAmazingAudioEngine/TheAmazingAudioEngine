Pod::Spec.new do |s|
  s.name         = "TheAmazingAudioEngine"
  s.version      = "1.5.6"
  s.summary      = "Core Audio, Cordially: A sophisticated framework for iOS audio applications, built so you don't have to."
  s.homepage     = "http://theamazingaudioengine.com"
  s.license      = 'zlib'
  s.author       = { "Michael Tyson" => "michael@atastypixel.com" }
  s.source       = { :git => "https://github.com/TheAmazingAudioEngine/TheAmazingAudioEngine.git", :tag => "1.5.6" }
  s.ios.deployment_target = '7.0'
  s.osx.deployment_target = '10.9'
  s.tvos.deployment_target = '9.0'
  s.source_files = 'TheAmazingAudioEngine/**/*.{h,m,c}', 'Modules/**/*.{h,m,c}'
  s.exclude_files = 'Modules/TPCircularBuffer'
  s.osx.exclude_files = 'Modules/Filters/AEReverbFilter.*'
  s.compiler_flags = '-DTPCircularBuffer=AECB',
					'-D_TPCircularBufferInit=_AECBInit',
					'-DTPCircularBufferCleanup=AECBClean',
					'-DTPCircularBufferClear=AECBClear',
					'-DTPCircularBufferSetAtomic=AECBSetAtomic',
					'-DTPCircularBufferTail=AECBTail',
					'-DTPCircularBufferConsume=AECBConsume',
					'-DTPCircularBufferHead=AECBHead',
					'-DTPCircularBufferProduce=AECBProduce',
					'-DTPCircularBufferProduceBytes=AECBProduceBytes',
					'-DTPCircularBufferPrepareEmptyAudioBufferList=AECBPrepareEmptyBL',
					'-DTPCircularBufferPrepareEmptyAudioBufferListWithAudioFormat=AECBPrepareEmptyBLWithAF',
					'-DTPCircularBufferProduceAudioBufferList=AECBProduceBL',
					'-DTPCircularBufferCopyAudioBufferList=AECBCopyBL',
					'-DTPCircularBufferNextBufferList=AECBNextBL',
					'-DTPCircularBufferNextBufferListAfter=AECBNextBLAfter',
					'-DTPCircularBufferConsumeNextBufferList=AECBConsumeBL',
					'-DTPCircularBufferGetAvailableSpace=AECBGetAvailableSpace',
					'-DTPCircularBufferConsumeNextBufferListPartial=AECBConsumeBLPartial',
					'-DTPCircularBufferDequeueBufferListFrames=AECBDequeueBLFrames',
					'-DTPCircularBufferPeek=AECBPeek',
					'-DTPCircularBufferPeekContiguous=AECBPeekContiguous',
					'-D_TPCircularBufferPeek=_AECBPeek'
  s.frameworks = 'AudioToolbox', 'Accelerate'
  s.requires_arc = true
end

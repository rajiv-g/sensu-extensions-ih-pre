# coding: utf-8

Gem::Specification.new do |spec|
  spec.name          = "sensu-extensions-ih"
  spec.version       = "1.0.0"
  spec.license       = "MIT"
  spec.authors       = ["Devops"]
  spec.email         = ["devops@introhive.com"]

  spec.summary       = "Introhive extensions for Sensu monitoring"
  spec.description   = "Introhive extensions for Sensu monitoring"
  spec.homepage      = "https://github.com/Introhive/sensu-extensions-ih"

  spec.files         = Dir.glob('{bin,lib}/**/*') + %w(README.md CHANGELOG.md)
  spec.require_paths = ["lib"]

  spec.add_dependency "sensu-extension"

  spec.add_development_dependency "bundler", "~> 1.6"
  spec.add_development_dependency "rake"
  spec.add_development_dependency "rspec"
  spec.add_development_dependency "sensu-logger"
  spec.add_development_dependency "sensu-settings"
  spec.add_development_dependency "rspec-benchmark"
end

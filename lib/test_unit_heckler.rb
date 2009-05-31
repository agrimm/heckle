#!/usr/bin/env ruby

require "test/unit/collector/objectspace"
require "test/unit/ui/testrunnermediator"
require 'heckle'
require 'zentest_mapping'

$: << 'lib' << 'test'

# Make sure test/unit doesn't swallow our timeout
begin
  Test::Unit::TestCase::PASSTHROUGH_EXCEPTIONS << Heckle::Timeout
rescue NameError
  # ignore
end

class TestUnitHeckler < Heckle

  @@test_pattern = 'test/test_*.rb'
  @@tests_loaded = false
  @@focus = false
  @@test_runner_mediator = nil

  def self.test_pattern=(value)
    @@test_pattern = value
  end

  def self.focus=(value)
    @@focus = value
  end

  def self.load_test_files
    @@tests_loaded = true
    Dir.glob(@@test_pattern).each {|test| require test}
  end

  def self.validate(klass_name, method_name = nil,
                    nodes = Heckle::MUTATABLE_NODES, force = false)
    load_test_files
    klass = klass_name.to_class

    # Does the method exist?
    klass_methods = klass.singleton_methods(false).collect {|meth| "self.#{meth}"}
    if method_name
      if method_name =~ /self\./
        abort "Unknown method: #{klass_name}.#{method_name.gsub('self.', '')}" unless klass_methods.include? method_name
      else
        abort "Unknown method: #{klass_name}##{method_name}" unless klass.instance_methods(false).include? method_name
      end
    end

    initial_time = Time.now

    heckle = self.new(klass_name)

    passed = heckle.tests_pass?

    unless force or passed then
      abort "Initial run of tests failed... fix and run heckle again"
    end

    if self.guess_timeout? then
      running_time = Time.now - initial_time
      adjusted_timeout = (running_time * 2 < 5) ? 5 : (running_time * 2).ceil
      self.timeout = adjusted_timeout
    end

    puts "Timeout set to #{adjusted_timeout} seconds."

    if passed then
      puts "Initial tests pass. Let's rumble."
    else
      puts "Initial tests failed but you forced things. Let's rumble."
    end
    puts

    methods = method_name ? Array(method_name) : klass.instance_methods(false) + klass_methods

    counts = Hash.new(0)
    methods.sort.each do |method_name|
      result = self.new(klass_name, method_name, nodes).validate
      counts[result] += 1
    end
    all_good = counts[false] == 0

    puts "Heckle Results:"
    puts
    puts "Passed    : %3d" % counts[true]
    puts "Failed    : %3d" % counts[false]
    puts "Thick Skin: %3d" % counts[nil]
    puts

    if all_good then
      puts "All heckling was thwarted! YAY!!!"
    else
      puts "Improve the tests and try again."
    end

    all_good
  end

  def initialize(klass_name=nil, method_name=nil, nodes=Heckle::MUTATABLE_NODES)
    super
    self.class.load_test_files unless @@tests_loaded
  end

  #Current thoughts:
  ## It doesn't print how many tests failed or their error messages
  ## The test runner mediator is only created once. Are there any downsides for this?
  ## Does --name=/#{name}/ work any more?

  include ZenTestMapping

  def tests_pass?
    if @@test_runner_mediator.nil?
      obj_sp = Test::Unit::Collector::ObjectSpace.new
      test_suite = HeckleFriendlyTestSuite.new("Heckle friendly test suite")
      test_suite << obj_sp.collect

      @@test_runner_mediator =  Test::Unit::UI::TestRunnerMediator.new(test_suite)
      @@test_runner_mediator.add_listener(Test::Unit::TestResult::FAULT) {throw :stop_test_runner}
    end

    silence_stream do
      if @@focus and @method_name then
        name = normal_to_test @method_name.to_s
        ARGV.clear
        ARGV << "--name=/#{name}/"
      end
      result = false
      catch (:stop_test_runner) do
        result = @@test_runner_mediator.run_suite
      end

      ARGV.clear
      result
    end
  end
end

class HeckleFriendlyTestSuite < Test::Unit::TestSuite
  def initialize(*args)
    @test_method_times = Hash.new(0)
    super(*args)
  end

  # Runs the tests contained in this TestSuite.

  # Normally, this would ask each test, which may be a test suite containing other tests,
  # to run itself. However, we want to run the fastest (and most likely to fail) methods
  # first, regardless of which suite they're in

  # To do: build a more sophisticated approach to weigh up how long a method takes, and
  # how likely it is to fail

  def run(result, &progress_block)
    yield(STARTED, name)
    test_cases = find_test_cases(@tests)
    test_cases = test_cases.sort_by{|test| @test_method_times[test.name]}
    test_cases.each do |test|
      @test_method_times[test.name] = @test_method_times[test.name] * 0.5 #In case the test fails
      start_time = Time.now
      test.run(result, &progress_block)
      @test_method_times[test.name] = Time.now - start_time
    end
    yield(FINISHED, name)
  end

  def find_test_cases(tests)
    result = []
    tests.each do |test|
      if test.respond_to?(:tests)
        result += find_test_cases(test.tests)
      else
        result << test
      end
    end
    result
  end
  private :find_test_cases

end

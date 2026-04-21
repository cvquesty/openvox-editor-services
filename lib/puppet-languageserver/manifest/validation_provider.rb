# frozen_string_literal: true

require 'puppet-lint'
module PuppetLanguageServer
  module Manifest
    module ValidationProvider
      # Similar to 'validate' this will run puppet-lint and returns
      # the manifest with any fixes applied
      #
      # Returns:
      #  [ <Int> Number of problems fixed,
      #    <String> New Content
      #  ]
      def self.fix_validate_errors(session_state, content)
        init_puppet_lint(session_state.documents.store_root_path)

        PuppetLint.configuration.fix = true
        linter = PuppetLint.new
        linter.path = 'stdin.pp'
        linter.code = content
        linter.run

        problems_fixed = linter.problems.nil? ? 0 : linter.problems.count { |item| item[:kind] == :fixed }

        [problems_fixed, linter.manifest]
      end

      def self.validate(session_state, content, options = {})
        options = {
          max_problems: 100,
          tasks_mode: false
        }.merge(options)

        result = []
        # TODO: Need to implement max_problems

        init_puppet_lint(session_state.documents.store_root_path)

        begin
          linter = PuppetLint.new
          linter.path = 'stdin.pp'
          linter.code = content
          linter.run

          unless linter.problems.nil?
            linter.problems.each do |problem|
              # Syntax errors are better handled by the puppet parser, not puppet lint
              next if problem[:kind] == :error && problem[:check] == :syntax
              # Ignore linting errors what were ignored by puppet-lint
              next if problem[:kind] == :ignored

              severity = case problem[:kind]
                         when :error
                           LSP::DiagnosticSeverity::ERROR
                         when :warning
                           LSP::DiagnosticSeverity::WARNING
                         else
                           LSP::DiagnosticSeverity::HINT
                         end

              endpos = problem[:column] - 1
              endpos = problem[:column] - 1 + problem[:token].to_manifest.length unless problem[:token].nil? || problem[:token].value.nil?

              result << LSP::Diagnostic.new('severity' => severity,
                                            'code' => problem[:check].to_s,
                                            'range' => LSP.create_range(problem[:line] - 1, problem[:column] - 1, problem[:line] - 1, endpos),
                                            'source' => 'Puppet',
                                            'message' => problem[:message])
            end
          end
        rescue StandardError
          # If anything catastrophic happens we resort to puppet parsing anyway
        end
        # TODO: Should I wrap this thing in a big rescue block?
        Puppet[:code] = content
        env = Puppet.lookup(:current_environment)
        loaders = Puppet::Pops::Loaders.new(env)
        Puppet.override({ loaders: }, 'For puppet parser validate') do
          validation_environment = env
          $PuppetParserMutex.synchronize do # rubocop:disable Style/GlobalVars
            original_taskmode = Puppet[:tasks] if Puppet.tasks_supported?
            Puppet[:tasks] = options[:tasks_mode] if Puppet.tasks_supported?
            validation_environment.check_for_reparse
            validation_environment.known_resource_types.clear
          ensure
            Puppet[:tasks] = original_taskmode if Puppet.tasks_supported?
          end
        rescue StandardError => e
          # Sometimes the error is in the cause not the root object itself
          e = e.cause if !e.respond_to?(:line) && e.respond_to?(:cause)
          ex_line = e.respond_to?(:line) && !e.line.nil? ? e.line - 1 : nil # Line numbers from puppet exceptions are base 1
          ex_pos = e.respond_to?(:pos) && !e.pos.nil? ? e.pos : nil # Pos numbers from puppet are base 1

          message = e.respond_to?(:message) ? e.message : nil
          message = e.basic_message if message.nil? && e.respond_to?(:basic_message)

          unless ex_line.nil? || ex_pos.nil? || message.nil?
            result << LSP::Diagnostic.new('severity' => LSP::DiagnosticSeverity::ERROR,
                                          'range' => LSP.create_range(ex_line, ex_pos, ex_line, ex_pos + 1),
                                          'source' => 'Puppet',
                                          'message' => message)
          end
        end

        result
      end

      def self.init_puppet_lint(root_dir)
        # Read .puppet-lint.rc from the workspace root if available
        if root_dir
          begin
            $PuppetParserMutex.synchronize do # rubocop:disable Style/GlobalVars
              Dir.chdir(root_dir.to_s) { PuppetLint::OptParser.build }
            end
          rescue OptionParser::InvalidOption => e
            PuppetLanguageServer.log_message(:error, "(#{name}) Error reading Puppet Lint configuration.  Using default: #{e}")
          end
        end
        PuppetLint.configuration.fix = false
      end
      private_class_method :init_puppet_lint
    end
  end
end

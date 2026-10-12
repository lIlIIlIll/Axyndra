require 'stringio'
require 'timeout'
STDOUT.write("READY|rb|1\n"); STDOUT.flush
def fresh_binding
  Object.new.instance_eval { binding }
end
state = fresh_binding
STDIN.each_line do |line|
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  out = StringIO.new
  err = StringIO.new
  exit_code = 0
  timed_out = false
  begin
    timeout_text, reset_text, payload = line.chomp.split('|', 3)
    timeout_ms = Integer(timeout_text)
    state = fresh_binding if reset_text == '1'
    code = [payload].pack('H*').force_encoding('UTF-8')
    previous_out, previous_err = $stdout, $stderr
    begin
      $stdout, $stderr = out, err
      value = Timeout.timeout(timeout_ms / 1000.0) { eval(code, state, '<eval>') }
      puts(value.inspect) unless value.nil?
    ensure
      $stdout, $stderr = previous_out, previous_err
    end
  rescue Timeout::Error
    timed_out = true
    exit_code = 124
    err.write('eval cell timed out')
  rescue Exception => error
    exit_code = 1
    err.write(([error.full_message].compact).join("\n"))
  end
  duration = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).to_i
  response = ['OK', exit_code, timed_out ? 1 : 0, duration, out.string.unpack1('H*'), err.string.unpack1('H*')].join('|')
  STDOUT.write(response + "\n")
  STDOUT.flush
end

require 'stringio'
require 'timeout'
require 'digest'
STDOUT.write("READY|rb|1\n"); STDOUT.flush
def fresh_binding
  Object.new.instance_eval { binding }
end
state = fresh_binding
STDIN.each_line do |line|
  artifacts = line.start_with?('A|')
  _, binding_id, line = line.split('|', 3) if artifacts
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
  data = [out.string, err.string]
  meta = [exit_code, timed_out ? 1 : 0, duration]
  if artifacts && data.sum(&:bytesize) > 4096
    raise 'cell output exceeds artifact bound' if data.sum(&:bytesize) > 16777216
    STDOUT.puts(['OUT', binding_id, *meta, *data.flat_map { |s| [s.bytesize, Digest::SHA256.hexdigest(s)] }].join('|'))
    data.each do |s|
      start = 0
      while start < s.bytesize
        stop = [s.bytesize, start + 16384].min
        stop -= 1 while stop < s.bytesize && (s.getbyte(stop) & 0xc0) == 0x80 && stop > start
        raise 'invalid output encoding' if stop == start
        STDOUT.puts(s.byteslice(start...stop).unpack1('H*'))
        start = stop
      end
    end
    STDOUT.puts("END|#{binding_id}")
  else
    STDOUT.puts([artifacts ? "INLINE|#{binding_id}" : 'OK', *meta, *data.map { |s| s.unpack1('H*') }].join('|'))
  end
  STDOUT.flush
end

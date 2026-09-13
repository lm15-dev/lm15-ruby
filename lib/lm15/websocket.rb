# frozen_string_literal: true
require 'socket'
require 'timeout'
module LM15
  # Minimal RFC 6455 client: TLS verification, masking, fragmentation, ping/pong,
  # bounded frames, one receiver and serialized writes. No extensions negotiated.
  class WebSocket
    MAX_MESSAGE = 16 * 1024 * 1024
    GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
    def initialize(url,headers: {},connect_timeout:10,read_timeout:120)
      uri = URI.parse(url)
      raise ValueError,'expected ws/wss URL with no userinfo or fragment' unless %w[ws wss].include?(uri.scheme) && !uri.userinfo && !uri.fragment
      @write_lock = Mutex.new; @read_lock = Mutex.new; @closed = false; @read_timeout = read_timeout
      port = uri.port || (uri.scheme == 'wss' ? 443 : 80)
      @socket = Socket.tcp(uri.host,port,connect_timeout:connect_timeout)
      if uri.scheme == 'wss'
        ctx = OpenSSL::SSL::SSLContext.new; ctx.set_params(verify_mode:OpenSSL::SSL::VERIFY_PEER)
        tls = OpenSSL::SSL::SSLSocket.new(@socket,ctx); tls.hostname = uri.host; tls.sync_close = true
        @socket = tls; ::Timeout.timeout(connect_timeout) { tls.connect }; tls.post_connection_check(uri.host)
      end
      key = Base64.strict_encode64(SecureRandom.random_bytes(16)); host = uri.host.include?(':') ? "[#{uri.host}]" : uri.host
      host += ":#{port}" unless port == (uri.scheme == 'wss' ? 443 : 80)
      values = {'Host'=>host,'Upgrade'=>'websocket','Connection'=>'Upgrade','Sec-WebSocket-Key'=>key,'Sec-WebSocket-Version'=>'13'}
      reserved = values.keys.map(&:downcase)
      headers.each do |k,v|
        raise ValueError,'reserved or invalid WebSocket header' if reserved.include?(k.downcase) || !k.match?(/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/) || v.to_s.match?(/[\r\n]/)
        values[k] = v
      end
      path = uri.path.empty? ? '/' : uri.path; path += "?#{uri.query}" if uri.query
      @socket.write("GET #{path} HTTP/1.1\r\n" + values.map { |k,v| "#{k}: #{v}\r\n" }.join + "\r\n")
      response = ''.b
      ::Timeout.timeout(connect_timeout) do
        until response.end_with?("\r\n\r\n")
          raise TransportError,'WebSocket handshake headers exceed limit' if response.bytesize >= 65_536
          response << read_exact(1)
        end
      end
      rows = response.split("\r\n"); status = rows.shift; h = {}
      rows.each do |row|
        k,v = row.split(':',2); raise TransportError,'malformed WebSocket handshake header' unless v
        name = k.downcase; h[name] = h[name] ? "#{h[name]},#{v.strip}" : v.strip
      end
      expected = Base64.strict_encode64(OpenSSL::Digest::SHA1.digest(key + GUID))
      unless status.match?(/\AHTTP\/1\.1 101(?: |$)/) && h['upgrade'].to_s.downcase == 'websocket' && h['connection'].to_s.downcase.split(/,\s*/).include?('upgrade') && h['sec-websocket-accept'] == expected && !h['sec-websocket-extensions'] && !h['sec-websocket-protocol']
        raise TransportError,'WebSocket upgrade rejected or invalid'
      end
    rescue StandardError => e
      @socket&.close rescue nil
      raise e if e.is_a?(LM15Error) || e.is_a?(ValueError)
      raise TransportError,'WebSocket connection failed'
    end
    def read_exact(n)
      bytes = ''.b
      while bytes.bytesize < n
        chunk = ::Timeout.timeout(@read_timeout) { @socket.read(n - bytes.bytesize) }
        raise TransportError,'WebSocket closed unexpectedly' unless chunk && !chunk.empty?
        bytes << chunk
      end
      bytes
    end
    def frame(op,data)
      data = data.b; raise TransportError,'WebSocket message exceeds limit' if data.bytesize > MAX_MESSAGE
      @write_lock.synchronize do
        raise TransportError,'WebSocket is closed' if @closed
        n = data.bytesize; prefix = [0x80 | op].pack('C')
        prefix << (n < 126 ? [0x80 | n].pack('C') : n <= 65_535 ? [0xfe,n].pack('Cn') : [0xff,n].pack('CQ>'))
        mask = SecureRandom.random_bytes(4); masked = data.bytes.each_with_index.map { |b,i| b ^ mask.getbyte(i % 4) }.pack('C*')
        ::Timeout.timeout(@read_timeout) { @socket.write(prefix + mask + masked) }
      end
    rescue IOError,SystemCallError,::Timeout::Error
      raise TransportError,'WebSocket write failed'
    end
    def send(text)
      text = text.encode(Encoding::UTF_8); raise ValueError,'WebSocket text must be valid UTF-8' unless text.valid_encoding?
      frame(1,text)
    end
    def recv
      raise TransportError,'WebSocket already has an active reader' unless @read_lock.try_lock
      begin
        message = ''.b; opcode = nil
        loop do
          return nil if @closed
          a,b = read_exact(2).unpack('CC'); fin = a & 0x80 != 0; op = a & 15; length = b & 127
          raise TransportError,'invalid WebSocket frame flags' if a & 0x70 != 0 || b & 0x80 != 0
          if length == 126
            length = read_exact(2).unpack1('n'); raise TransportError,'nonminimal frame length' if length < 126
          elsif length == 127
            length = read_exact(8).unpack1('Q>'); raise TransportError,'invalid frame length' if length < 65_536 || length >= 2**63
          end
          raise TransportError,'WebSocket message exceeds limit' if length + message.bytesize > MAX_MESSAGE
          raise TransportError,'invalid control frame' if op >= 8 && (!fin || length > 125)
          payload = read_exact(length)
          case op
          when 8
            raise TransportError,'invalid close frame' if length == 1
            if length >= 2
              code = payload.unpack1('n'); reason = payload.byteslice(2..).force_encoding(Encoding::UTF_8)
              raise TransportError,'invalid close code or reason' unless ((1000..1014).cover?(code) && ![1004,1005,1006].include?(code) || (3000..4999).cover?(code)) && reason.valid_encoding?
            end
            frame(8,payload); @closed = true; @socket.close; return nil
          when 9 then frame(10,payload); next
          when 10 then next
          when 0 then raise TransportError,'unexpected continuation frame' unless opcode
          when 1,2
            raise TransportError,'interleaved fragmented messages' if opcode
            opcode = op
          else raise TransportError,'unknown WebSocket opcode' end
          message << payload
          next unless fin
          if opcode == 1
            message.force_encoding(Encoding::UTF_8); raise TransportError,'invalid WebSocket UTF-8' unless message.valid_encoding?
          end
          return message
        end
      rescue IOError,SystemCallError,::Timeout::Error
        raise TransportError,'WebSocket read failed'
      rescue LM15Error
        @closed = true; @socket.close rescue nil; raise
      ensure
        @read_lock.unlock
      end
    end
    def close
      return if @closed
      begin frame(8,[1000].pack('n')); rescue StandardError; end
      @closed = true; @socket.close
    rescue IOError,SystemCallError
      nil
    end
    def inspect = '#<LM15::WebSocket>'
  end
end

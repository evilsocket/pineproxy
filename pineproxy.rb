#!/usr/bin/env ruby

=begin

PINEPROXY

Author : Simone 'evilsocket' Margaritelli
Email  : evilsocket@gmail.com
Blog   : http://www.evilsocket.net/

This project is released under the GPL 3 license.

=end
require 'socket'
require 'uri'
require 'optparse'

begin
    require 'colorize'

    HAVE_COLORIZE = true
rescue LoadError
    HAVE_COLORIZE = false
end

module PineProxy

VERSION = '1.0.0'

class Logger
    LEVEL_DEBUG = 3
    LEVEL_INFO  = 2
    LEVEL_WARN  = 1
    LEVEL_ERROR = 0

    LEVEL_LABELS = {
        LEVEL_DEBUG => 'DBG',
        LEVEL_INFO  => 'INF',
        LEVEL_WARN  => 'WAR',
        LEVEL_ERROR => 'ERR'
    }

    LEVEL_COLORS = {
        LEVEL_DEBUG => :light_black,
        LEVEL_INFO  => nil,
        LEVEL_WARN  => :yellow,
        LEVEL_ERROR => :red
    }

    @@level   = LEVEL_INFO
    @@logfile = nil

    def self.set_verbosity(level)
        raise "Invalid verbosity level" unless level >= 0 and level <= LEVEL_DEBUG

        @@level = level
    end

    def self.set_logfile(filename)
        @@logfile = filename
    end

    def self.colorize?
        @@logfile.nil? and HAVE_COLORIZE
    end

    def self.error(message)
        log formatted_message( LEVEL_ERROR, message )
    end

    def self.warn(message)
        log formatted_message( LEVEL_WARN, message )
    end

    def self.info(message)
        log formatted_message( LEVEL_INFO, message )
    end

    def self.debug(message)
        log formatted_message( LEVEL_DEBUG, message )
    end

    private
    def self.log( message )
        return unless message

        if @@logfile.nil?
            puts message
        elsif level <= @@level
            open( @@logfile, 'a+t' ) do |f|
                f << "#{message}\n"
            end
        end
    end

    def self.formatted_message(level, message)
        return nil unless level <= @@level

        formatted = "[#{Time.now}] [#{LEVEL_LABELS[level]}] #{message}"

        # do not colorize if we're loggin to a file
        if self.colorize? and LEVEL_COLORS[level]
            formatted = formatted.colorize LEVEL_COLORS[level]
        end

        formatted
    end
end

class Module
    @@modules = []

    def self.modules
        @@modules
    end

    def self.register_modules
        Object.constants.each do |klass|
            const = Kernel.const_get(klass)
            if const.respond_to?(:superclass) and const.superclass == self
                Logger.debug "Registering module #{const}"
                @@modules << const.new
            end
        end
    end
end

class Request
    attr_reader :lines, :verb, :url, :host, :port, :content_length

    def initialize
        @lines  = []
        @verb   = nil
        @url    = nil
        @host   = nil
        @port   = 80
        @content_length = 0
    end

    def <<(line)
        line = line.chomp

        if @url.nil? and line =~ /^(\w+)\s+(\S+)\s+HTTP\/[\d\.]+\s*$/
            @verb    = $1
            @url     = $2

            # fix url
            if @url.include? "://"
                uri = URI::parse @url
                @url = "#{uri.path}" + ( uri.query ? "?#{uri.query}" : "" )
            end

            line = "#{@verb} #{url} HTTP/1.0"

        elsif line =~ /^Host: (.*)$/
            @host = $1
            if host =~ /([^:]*):([0-9]*)$/
                @host = $1
                @port = $2.to_i
            end

        elsif line =~ /^Content-Length:\s+(\d+)\s*$/i
            @content_length = $1.to_i

        elsif line =~ /Connection: keep-alive/i
            line = "Connection: close"

        elsif line =~ /^Accept-Encoding:.*/i
            line = "Accept-Encoding: identity"

        end

        @lines << line
    end

    def is_post?
        return @verb == 'POST'
    end

    def to_s
        return @lines.join("\n") + "\n"
    end
end

class Response
    attr_reader :content_type, :content_length, :headers, :code, :headers_done
    attr_accessor :body

    def initialize
        @content_type = nil
        @content_length = nil
        @body = ""
        @code = nil
        @headers = []
        @headers_done = false
    end

    def <<(line)
        if @headers_done
            @body += line
        else
            if @code.nil? and line =~ /^HTTP\/[\d\.]+\s+(.+)/
                @code = $1.chomp

            elsif line =~ /^Content-Type: ([^;]+).*/i
                @content_type = $1.chomp

            elsif line =~ /^Content-Length:\s+(\d+)\s*$/i
                @content_length = $1.to_i

            elsif line.chomp == ""
                @headers_done = true

            end

            @headers << line.chomp
        end
    end

    def is_textual?
        @content_type and @content_type =~ /^text\/.+/
    end

    def to_s
        if is_textual?
            @headers.map! do |header|
                # update content length in case the body was
                # modified
                if header =~ /Content-Length:\s*(\d+)/i
                    "Content-Length: #{@body.size}"
                else
                    header
                end
            end
        end

        @headers.join("\n") + "\n" + @body
    end
end

class Proxy
    def initialize address, port, &processor
        @socket      = nil
        @address     = address
        @port        = port
        @main_thread = nil
        @running     = false
        @processor   = processor
    end

    def start
        begin
            @socket = TCPServer.new( @address, @port )
            @main_thread = Thread.new &method(:server_thread)
        rescue Exception => e
            Logger.error "Error starting proxy: #{e.inspect}"
            @socket.close unless @socket.nil?
        end
    end

    def stop
        if @socket and @running
            @socket.close
            @running = false
        end
    end

    private

    def server_thread
        Logger.info "Server started on #{@address}:#{@port} ..."

        @running = true

        begin
            while @running do
                Thread.new @socket.accept, &method(:client_thread)
            end
        rescue Exception => e
            Logger.error "Error while accepting connection: #{e.inspect}"
        ensure
            @socket.close unless @socket.nil?
        end
    end

    def binary_streaming from, to, opts = {}

        total_size = 0

        if not opts[:response].nil?
            to.write opts[:response].to_s

            total_size = opts[:response].content_length unless opts[:response].content_length.nil?
        elsif not opts[:request].nil?

            total_size = opts[:request].content_length unless opts[:request].content_length.nil?
        end

        buff = ""
        read = 0

        if total_size
            chunk_size = 1024
        else
            chunk_size = [ 1024, total_size ].min
        end

        if chunk_size > 0
            loop do
                from.read chunk_size, buff

                break unless buff.size > 0

                to.write buff

                read += buff.size

                if not opts[:request].nil? and opts[:request].is_post?
                    opts[:request] << buff
                end

                break unless read != total_size
            end
        end
    end

    def html_streaming request, response, from, to
        buff = ""
        loop do
            from.read 1024, buff

            break unless buff.size > 0

            response << buff
        end

        @processor.call( request, response )

        to.write response.to_s
    end

    def log_stream client, request, response
        client_s   = "[#{client}]"
        verb_s     = request.verb.light_blue
        request_s  = "http://#{request.host}#{request.url}"
        response_s = "( #{response.content_type} )"
        request_s  = request_s.slice(0..50) + "..." unless request_s.length <= 50

        if Logger.colorize?
            if response.code[0] == '2'
                response_s += " [#{response.code}]".green
            elsif response.code[0] == '3'
                response_s += " [#{response.code}]".light_black
            elsif response.code[0] == '4'
                response_s += " [#{response.code}]".yellow
            elsif response.code[0] == '5'
                response_s += " [#{response.code}]".red
            else
                response_s += " [#{response.code}]"
            end
        else
            response_s += " [#{response.code}]"
        end

        Logger.info "#{client_s} #{verb_s} #{request_s} #{response_s}"
    end

    def client_thread client
        client_port, client_ip = Socket.unpack_sockaddr_in(client.getpeername)
        Logger.debug "New connection from #{client_ip}:#{client_port}"

        server = nil
        request = Request.new

        begin
            # read the first line
            request << client.readline

            loop do
                line = client.readline
                request << line

                if line.chomp == ""
                    break
                end
            end

            raise "Couldn't extract host from the request." unless request.host

            server = TCPSocket.new( request.host, request.port )

            server.write request.to_s

            if request.content_length > 0
                Logger.debug "Getting #{request.content_length} bytes from client"

                binary_streaming client, server, :request => request
            end

            Logger.debug "Reading response ..."

            response = Response.new

            loop do
                line = server.readline

                response << line

                break unless not response.headers_done
            end

            if response.is_textual?
                log_stream client_ip, request, response

                Logger.debug "Detected textual response"

                html_streaming request, response, server, client
            else
                Logger.debug "[#{client_ip}] -> #{request.host}#{request.url} [#{response.code}]"

                Logger.debug "Binary streaming"

                binary_streaming server, client, :response => response
            end

            Logger.debug "#{client_ip}:#{client_port} served."

        rescue Exception => e
            if request.host
                Logger.debug "Error while serving #{request.host}#{request.url}: #{e.inspect}"
                Logger.debug e.backtrace
            end
        ensure
            client.close
            server.close unless server.nil?
        end
    end
end

end

puts "--------------------------------------------"
puts "PineProxy v#{PineProxy::VERSION}"
puts "Copyleft by Simone 'evilsocket' Margaritelli"
puts "--------------------------------------------\n\n"

options = {
    :address   => '0.0.0.0',
    :port      => 8080,
    :modules   => File.expand_path( File.dirname(__FILE__) + '/modules' ),
    :verbosity => PineProxy::Logger::LEVEL_INFO,
    :logfile   => nil
}

OptionParser.new do |opts|
    opts.banner = "Usage: #{$0} [options]"

    opts.on( "-A", "--address ADDRESS", "Address to listen on - default: #{options[:address]}" ) do |v|
        options[:address] = v
    end

    opts.on( "-P", "--port PORT", "Port to listen on - default: #{options[:port]}" ) do |v|
        options[:port] = v.to_i
    end

    opts.on( "-M", "--modules PATH", "Path of modules to load - default: #{options[:modules]}" ) do |v|
        options[:modules] = v
    end

    opts.on( "-V", "--verbosity LEVEL", "Verbosity level between #{PineProxy::Logger::LEVEL_DEBUG} and #{PineProxy::Logger::LEVEL_ERROR} - default: #{options[:verbosity]}" ) do |v|
        options[:verbosity] = v.to_i
    end

    opts.on( "-L", "--logfile FILE", "Log on this file instead of the stdout." ) do |v|
        options[:logfile] = v
    end
end.parse!

# load modules from the given path
Dir["#{options[:modules]}/*.rb"].each { |f| require f }
# setup the logger
PineProxy::Logger.set_verbosity options[:verbosity]
PineProxy::Logger.set_logfile options[:logfile]
# register modules inside the system
PineProxy::Module.register_modules

proxy = PineProxy::Proxy.new( options[:address], options[:port] ) do |request,response|
    # loop each loaded module and execute if enabled
    PineProxy::Module.modules.each do |mod|
        if mod.is_enabled?
            mod.on_request request, response
        end
    end
end

proxy.start

begin
    loop do
        PineProxy::Logger.debug "#{Thread.list.count} THREADS - #{Thread.list.select {|thread| thread.status == "sleep"}.count} SLEEPING"
        sleep 1
    end
rescue Interrupt
    PineProxy::Logger.warn "Stopping proxy ..."
    proxy.stop
end

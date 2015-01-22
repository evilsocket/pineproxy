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
require 'colorize'

module PineProxy

class Logger
    def Logger.error(message)
        log formatted_message(message, "ERR").red
    end

    def Logger.warn(message)
        log formatted_message(message, "WAR").yellow
    end

    def Logger.info(message)
        log formatted_message(message, "INF")
    end

    def Logger.debug(message)
        # log formatted_message(message, "DBG").light_black
    end

    private
    def Logger.log(message)
        puts message
    end

    def Logger.formatted_message(message, message_type)
        "[#{Time.now}] [#{message_type}] #{message}"
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
        @socket.close
        @running = false
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

proxy = PineProxy::Proxy.new( '0.0.0.0', 8080 ) do |request,response|
    # is an html page?
    if response.content_type == "text/html"
        # do your injection here

        # url = "http://#{request.host}#{request.url}"
        # url = url.slice(0..50) + "..." unless url.length <= 50
        # PineProxy::Logger.debug "! PATCHING #{url} !"

        # if request.verb == 'POST'
        #    puts request.to_s
        #end

        # response.body.sub( "<title>", "<title> !!! HACKED !!!" )
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

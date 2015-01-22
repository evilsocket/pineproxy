class HelloWorld < PineProxy::Module
    def initialize

    end

    def is_enabled?
        return false
    end

    def on_request request, response
        puts "Hello World!"
    end
end

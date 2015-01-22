class HackTitle < PineProxy::Module
    def initialize

    end

    def is_enabled?
        return true
    end

    def on_request request, response
        # is an html page?
        if response.content_type == "text/html"
            url = "http://#{request.host}#{request.url}"
            url = url.slice(0..50) + "..." unless url.length <= 50
            PineProxy::Logger.warn "Hacking #{url} title tag"

            response.body.sub!( "<title>", "<title> !!! HACKED !!! " )
        end
    end
end

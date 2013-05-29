http = require "http"
url = require "url"
fs = require "fs"
path = require "path"
util = require "util"
events = require "events"

uuid = require "node-uuid"
uploads = require "node-persist"




setup = new events.EventEmitter()
config = {}


#Implements Browser Uploads
optionsFile = (req, res, query, matches) ->
    httpStatus res, 200, "Ok"

#Implements 6.1. File Creation
createFile = (req, res, query, matches) ->
    fileId = matches[2]

    return httpStatus res, 400, "Invalid Request" if fileId?

    #6.1.3.1. POST
    #The request MUST include a Final-Length header
    return httpStatus res, 400, "Final-Length Required" unless req.headers["final-length"]?

    finalLength = parseInt req.headers["final-length"]

    #The value MUST be a non-negative integer.
    return httpStatus res, 400, "Final-Length Must be Non-Negative" if isNaN finalLength || finalLength < 0

    #generate fileId
    fileId = uuid.v1()

    try
        filePath = path.join config.files, fileId
        fs.openSync filePath, 'w'
    catch error
        util.log util.inspect error
        return httpStatus res, 500, "Create Failed"

    uploads.setItem fileId, {finalLength: finalLength, state: "created", createdOn: Date.now(), offset: 0}
    res.setHeader "Location", "http://#{config.host}:#{config.port}/files/#{fileId}"
    httpStatus res, 201, "Created"

#Implements 5.3.1. HEAD
headFile = (req, res, query, matches) ->
    fileId = matches[2]
    return httpStatus res, 404, "Not Found" unless fileId?

    filePath = path.join config.files, fileId
    return httpStatus res, 404, "Not Found" unless fs.existsSync filePath 
 

    currentUpload = uploads.getItem fileId
    return httpStatus res, 404, "File Not Found" unless currentUpload?

    if not offset?
        try
            stat = fs.statSync filePath
            currentUpload.offset = stat.size
            uploads.setItem fileId , currentUpload
        catch e
            util.log "file error #{fileId} #{util.inspect e}"
            return httpStatus res, 500, "File Error"

    res.setHeader "Offset", currentUpload.offset
    httpStatus res, 200, "Ok"

#Implements 5.3.2. PATCH
patchFile = (req, res, query, matches) ->
    fileId = matches[2]
    return httpStatus res, 404, "Not Found" unless fileId?

    filePath = path.join config.files, fileId
    return httpStatus res, 404, "Not Found" unless fs.existsSync filePath

    #All PATCH requests MUST use Content-Type: application/offset+octet-stream.
    return httpStatus res, 400, "Content-Type Required" unless req.headers["content-type"]?
 
    return httpStatus res, 400, "Content-Type Invalid" unless req.headers["content-type"] is "application/offset+octet-stream"


    #5.2.1. Offset
    return httpStatus res, 400, "Offset Required" unless req.headers["offset"]?

    #The value MUST be an integer that is 0 or larger
    offsetIn = parseInt req.headers["offset"]
    return httpStatus res, 400, "Offset Invalid" if isNaN offsetIn or offsetIn < 0

    return httpStatus res, 400, "Content-Length Required" unless req.headers["content-length"]?

    contentLength = parseInt req.headers["content-length"]
    return httpStatus res, 400, "Invalid Content-Length" if isNaN contentLength or contentLength < 1

    currentUpload = uploads.getItem fileId    
    return httpStatus res, 404, "File Not Found" unless currentUpload?
    
    offset =  currentUpload.offset
    if not offset?
        try
            stat = fs.statSync filePath
            currentUpload.offset = stat.size
            uploads.setItem fileId, currentUpload
        catch e
            util.log "file error #{fileId} #{util.inspect e}"
            return httpStatus res, 500, "File Error"

    return httpStatus res, 400, "Offset Range Exceeded" unless offsetIn <= currentUpload.offset

    #Open file for writing
    ws = fs.createWriteStream filePath, {flags: "r+", start: offsetIn}
    #util.log util.inspect ws

    unless ws?
        util.log "unable to create file #{filePath}"
        return httpStatus res, 500, "File Error"

    currentUpload.offset = offsetIn
    currentUpload.state = "patched"
    currentUpload.patchedOn = Date.now()
    currentUpload.bytesReceived = 0 
    uploads.setItem fileId, currentUpload

    req.pipe ws

    req.on "data", (buffer) ->
        util.log "old Offset #{currentUpload.offset}"
        currentUpload.bytesReceived += buffer.length
        currentUpload.offset +=  buffer.length
        util.log "new Offset #{currentUpload.offset}"
        return httpStatus res, 500, "Exceeded Final-Length" unless currentUpload.offset <= currentUpload.finalLength
        return httpStatus res, 500, "Exceeded Content-Length" unless currentUpload.received <= contentLength
        uploads.setItem fileId, currentUpload


    ws.on "close", ->
        #util.log "closed the file stream #{fileId}"
        #util.log util.inspect res
        httpStatus res, 200, "Ok" unless res.headersSent

    ws.on "error", (e) ->
        util.log "closed the file stream #{fileId} #{util.inspect e}"
        #Send response
        return httpStatus res, 500, "File Error"

httpStatus = (res, statusCode, reason) ->
    res.writeHead statusCode, reason
    res.end()

ALLOWED_METHODS = ["HEAD", "PATCH", "POST", "OPTIONS"]
ALLOWED_METHODS_STR = ALLOWED_METHODS.join ","
PATTERNS = [
    {match:/files(\/(.+))*/, HEAD:headFile, PATCH:patchFile, POST:createFile, OPTIONS:optionsFile}
]
route = (req, res) ->
    #util.log util.inspect req
    return httpStatus res, 405, "Not Allowed" unless req.method in ALLOWED_METHODS

    #Get request param handling
    parsed = url.parse req.url, true
    urlPath = parsed.pathname

    return httpStatus res, 405, "Not Allowed" unless urlPath.length > 1
    
    query = parsed.query
    #util.log urlPath
    for pattern in PATTERNS
        matches = urlPath.match pattern.match
        util.log "matches #{util.inspect matches}"
        if matches?
             return pattern[req.method](req, res, query, matches)
    return httpStatus res, 405, "Not Allowed"


commonHeaders = (res) ->
    res.setHeader "Server", config.server
    res.setHeader "Access-Control-Allow-Origin", "*"
    res.setHeader "Access-Control-Allow-Methods", ALLOWED_METHODS_STR
    res.setHeader "Access-Control-Allow-Headers", "Origin, X-Requested-With, Content-Type, Accept"
    res.setHeader "Access-Control-Expose-Headers", "Location"
    res.setHeader "Content-Length", 0 #This is default

tusHandler = (req, res) ->
    commonHeaders(res)
    route req, res

#load config, create files folder
initApp = (args) ->
    #hacky but works
    #my configuration -> scriptname.json
    configFileName = path.join(path.dirname(args[1]), "#{path.basename args[1], path.extname args[1]}.json")
    util.log "Reading #{configFileName}"
    config = require configFileName

    #util.log util.inspect config

    try
        fs.mkdirSync config.files
    catch error
        if error? and error.code isnt "EEXIST"
            util.log util.inspect error
            process.exit 1

    try
        uploads.initSync({logging:true})
        uploads.values (vals) -> console.log vals
    catch error
        util.log util.inspect error
        process.exit 1

    setup.emit "setupComplete"

startup = (args) ->
    setup.once "setupComplete", -> 
        server = http.createServer tusHandler
        server.timeout = 30000 #servers SHOULD use a 30 second timeout
        server.listen config.port
        util.log "Server running at http://#{config.host}:#{config.port}/" 

    initApp args

startup process.argv
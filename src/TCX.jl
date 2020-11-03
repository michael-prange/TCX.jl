module TCX
using EzXML, Dates, DataFrames, Geodesy, Mocking
import Base.show

export parse_tcx_dir, parse_tcx_file, getActivityType, getDataFrame, getDistance, getDistance2, getDuration, getAverageSpeed, getAveragePace

const OK = 200
const CLIENT_ERROR = 400
const CLIENT_TCX_ERROR = 401
const NOT_FOUND = 404
const SERVER_ERROR = 500

struct TrackPoint
    Time::DateTime
    Latitude::Float64
    Longtitude::Float64
    HeartRateBpm::Int32
    AltitudeMeter::Float64
    DistanceMeter::Float64
end

struct TCXRecord
    Id::DateTime
    Name::String
    ActivityType::String
    DistanceStatic::Float64
    DurationStatic::Float64
    HeartRate::Int32
    TrackPoints::Array{TrackPoint}
end

function parse_tcx(tcxdoc::EzXML.Document)
    root_element = root(tcxdoc)
    # Check if TCX
    if nodename(root_element) != "TrainingCenterDatabase"
        return CLIENT_TCX_ERROR, nothing
    end

    activities = findnode(root_element, "Activities")
    activity = findnode(activities, "Activity")
    aType = activity["Sport"]
    id = findnode(activity, "Id")
    xid = nodecontent(id)
    aId = convertToDateTime(xid)
    lap = findnode(activity, "Lap")
    aName = nodecontent(lap)
    xtime = findnode(lap, "TotalTimeSeconds")
    aTime = parse(Float64, nodecontent(xtime))
    xDistance= findnode(lap, "DistanceMeters")
    aDistance = nodecontent0(Float64, xDistance)
    xbpm = findnode(lap, "AverageHeartRateBpm", false)
    aHeartRateBpm = (xbpm === nothing) ? 0 : nodecontent0(Int32, firstelement(xbpm))
    tp_Points = findnode(lap, "Track")
    aTrackPoints = Array{TrackPoint, countelements(tp_Points)}[]
    for tp in elements(tp_Points)
        xtime = nodecontent(findnode(tp, "Time"))
        tp_time = convertToDateTime(xtime)
        position = findnode(tp, "Position", false)
        if position == nothing
            tp_lat = tp_lon = 0.0
        else
            tp_lat = nodecontent0(Float64, findnode(position, "LatitudeDegrees"))
            tp_lon = nodecontent0(Float64, findnode(position, "LatitudeDegrees"))
        end
        xbpm = findnode(tp, "HeartRateBpm", false)
        tp_bpm = (xbpm === nothing) ? 0 : nodecontent0(Int32, firstelement(xbpm))
        tp_dist = nodecontent0(Float32, findnode(tp, "DistanceMeters", false))
        tp_alt = nodecontent0(Float64, findnode(tp, "AltitudeMeters", false))

        aTrackPoints = vcat(aTrackPoints, TrackPoint(tp_time, tp_lat, tp_lon, tp_bpm, tp_alt, tp_dist))
    end

    return OK, TCXRecord(aId, aName, aType, aDistance, aTime, aHeartRateBpm, aTrackPoints)
end

function parse_tcx_str(str::String)
    try
        status, parsed_tcx = parse_tcx(EzXML.parsexml(str))
        warn_on_tcx_error(status, str, false)
        return status, parsed_tcx
    catch e
        if isa(e, EzXML.XMLError)
            @error "Invalid XML string: $str"
            return CLIENT_ERROR, nothing
        end
    end
end

function parse_tcx_file(file::String)
    file_path = abspath(file)
    if isfile(file_path) == false
        return NOT_FOUND, nothing
    end
    xmldoc = try @mock EzXML.readxml(file_path)
    catch e
       if isa(e, EzXML.XMLError)
           # Not a valid XML document
           @warn "Invalid XML document: $file_path"
           return CLIENT_ERROR, nothing
       else
           throw(e)
       end
    end

    status, parsed_tcx = parse_tcx(xmldoc)
    warn_on_tcx_error(status, file_path, true)

    return status, parsed_tcx
end

function warn_on_tcx_error(status::Int, thing::String, isFile::Bool)
    if status == CLIENT_TCX_ERROR
        @warn "Invalid TCX $(isFile ? document : string): $(thing)"
    end
end

# Returns <code>nodecontent(node)</code>, or zero::dType if node==nothing.
function nodecontent0(dType, node)
    if node !== nothing
        return parse(dType, nodecontent(node))
    else
        return dType(0)
    end
end

# Returns the first occurance of a child node of <code>node</code> 
# named <code>name</code>. Returns <code>nothing</code> if there
# is no such node. Issue a warning if <code>warn</code> is true.
function findnode(node::EzXML.Node, name::String, warn::Bool=true)
    n = firstnode(node)
    while(nodename(n) !== name && hasnextnode(n))
        n = nextnode(n)
    end
    if nodename(n) == name
        return n
    else
        if warn
            @warn "Can't find $name"
        end
        return nothing
    end
end
                            
function parse_tcx_dir(path::String)
    if ispath(path) == false
        @warn "Invalid path: $path"
        return SERVER_ERROR, nothing
    end

    tcxArray = Array{TCXRecord}[]
    searchdir(path, key) = filter(x->occursin(key, x), readdir(path))

    for f in searchdir(path, ".tcx")
        err, tcx = parse_tcx_file(joinpath(path, f))
        if err == OK
            tcxArray = vcat(tcxArray, tcx)
        end
    end

    if length(tcxArray) > 0
        return OK, tcxArray
    else
        return NOT_FOUND, nothing
    end
end

function getActivityType(record::TCXRecord)
    return record.ActivityType
end

function getDataFrame(record::TCXRecord)
    return DataFrame(record.TrackPoints)
end

function getDataFrame(tcxArray::Array{Any, 1})
    aTP = Array{TrackPoint}[]
    for t in tcxArray
        aTP = vcat(aTP, t.TrackPoints)
    end
    return DataFrame(aTP)
end

function getDistance(record::TCXRecord)
    return record.DistanceStatic
end

function getDistance2(record::TCXRecord)
    total_distance = 0
    df = getDataFrame(record)
    num_of_rows = size(df, 1)
    for i in 1:num_of_rows
        if i < num_of_rows
            total_distance += distance(
                                       LLA(df[i, :Latitude], df[i, :Longtitude], df[i, :AltitudeMeter]),
                                       LLA(df[i+1, :Latitude], df[i+1, :Longtitude], df[i+1, :AltitudeMeter])
               )
        end
    end
    return total_distance
end

function getAverageSpeed(record::TCXRecord)
    return (record.DistanceStatic /1000) / (record.DurationStatic / 3600)  # km/h
end

function getAveragePace(record::TCXRecord)
    return (record.DurationStatic / 60) / (record.DistanceStatic / 1000) # min/km
end

function getDuration(record::TCXRecord)
    return record.DurationStatic
end

#=
= Converts a datetime string into the proper datetime based on string length.
=
= Will assume that an ArgumentError is due to
= https://github.com/JuliaLang/julia/issues/23049 and will attempt to work
= around this.
=#
function convertToDateTime(datestr::String)::DateTime
    m = match(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z?|\.\d{1,3}Z?)", datestr)
    format_prefix = "yyyy-mm-ddTHH:MM:SS"
    if m === nothing
        msg = "'$(datestr)' is improperly formatted. Must be in the form "
        msg = msg * "'$(format_prefix)Z' or '$(format_prefix).sssZ'"
        throw(ArgumentError(msg))
    else
        suffix = replace(m.captures[1], r"\d" => "s")
        try
            return @mock DateTime(m.match, format_prefix * suffix)
        catch e
            if isa(e, ArgumentError)
                # OK! FINE! NO Z THEN!
                return DateTime(m.match[1:end-1], format_prefix * (suffix[1:end-1]))
            else
                throw(e)
            end
        end
    end
end

Base.show(io::IO, tcx::TCXRecord) = print(io, "$(tcx.ActivityType) $(tcx.DistanceStatic/1000) km at $(tcx.Id) for $(tcx.DurationStatic) seconds.")
end #module_end

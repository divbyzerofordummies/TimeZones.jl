module Compiling

using Dates
using TimeZones

function main()::Cint
    
    date = Date(2018, 6, 14)
    zdt = ZonedDateTime(date, warsaw)

    return 0
end


end # module Compiling

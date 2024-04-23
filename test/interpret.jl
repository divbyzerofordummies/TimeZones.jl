using Dates: Millisecond, Hour, Minute, DateTime
using TimeZones: transition_range, interpret

@testset "lt_local / lt_utc" begin
    t = Transition(DateTime(1977, 5, 26, 1), FixedTimeZone("PDT", -8 * 3600, 3600))
    ms = Millisecond(1)

    @testset "lt_local" begin
        local_dt = DateTime(1977, 5, 25, 18)

        @test TimeZones.lt_local(local_dt - ms, t)
        @test !TimeZones.lt_local(local_dt, t)
        @test !TimeZones.lt_local(local_dt + ms, t)

        @test !TimeZones.lt_local(t, local_dt - ms)
        @test !TimeZones.lt_local(t, local_dt)
        @test TimeZones.lt_local(t, local_dt + ms)
    end

    @testset "lt_utc" begin
        utc_dt = DateTime(1977, 5, 26, 1)

        @test TimeZones.lt_utc(utc_dt - ms, t)
        @test !TimeZones.lt_utc(utc_dt, t)
        @test !TimeZones.lt_utc(utc_dt + ms, t)

        @test !TimeZones.lt_utc(t, utc_dt - ms)
        @test !TimeZones.lt_utc(t, utc_dt)
        @test TimeZones.lt_utc(t, utc_dt + ms)
    end
end

@testset "transition_range" begin
    # TODO: Redundancy with test from ZonedDateTime
    @testset "multiple hour transitions" begin
        # Transitions changes that exceed an hour. Results in having two sequential
        # non-existent hour and two sequential ambiguous hours.
        tz = VariableTimeZone("Testing", [
            Transition(DateTime(1800,1,1), FixedTimeZone("TST",0,0)),
            Transition(DateTime(1950,4,1), FixedTimeZone("TDT",0,7200)),
            Transition(DateTime(1950,9,1), FixedTimeZone("TST",0,0)),
        ])

        ### Local ###

        # Initial transition
        @test transition_range(DateTime(1799, 12, 31, 23), tz, Local) == 1:0
        @test transition_range(DateTime(1800, 01, 01, 00), tz, Local) == 1:1

        # A "spring forward" where 2 hours are skipped.
        @test transition_range(DateTime(1950, 03, 31, 23), tz, Local) == 1:1
        @test transition_range(DateTime(1950, 04, 01, 00), tz, Local) == 2:1  # 00:00 TST/TDT
        @test transition_range(DateTime(1950, 04, 01, 01), tz, Local) == 2:1  # 01:00 TST/TDT
        @test transition_range(DateTime(1950, 04, 01, 02), tz, Local) == 2:2

        # A "fall back" where 2 hours are duplicated. Never appears to occur in reality.
        @test transition_range(DateTime(1950, 08, 31, 23), tz, Local) == 2:2
        @test transition_range(DateTime(1950, 09, 01, 00), tz, Local) == 2:3  # 00:00 TDT/TST
        @test transition_range(DateTime(1950, 09, 01, 01), tz, Local) == 2:3  # 01:00 TDT/TST
        @test transition_range(DateTime(1950, 09, 01, 02), tz, Local) == 3:3

        ### UTC ###

        # Initial transition
        @test transition_range(DateTime(1799, 12, 31, 23), tz, UTC) == 1:0
        @test transition_range(DateTime(1800, 01, 01, 00), tz, UTC) == 1:1

        # A "spring forward" where 2 hours are skipped.
        @test transition_range(DateTime(1950, 03, 31, 23), tz, UTC) == 1:1  # 23:00 TST
        @test transition_range(DateTime(1950, 04, 01, 00), tz, UTC) == 2:2  # 02:00 TDT

        # A "fall back" where 2 hours are duplicated. Never appears to occur in reality.
        @test transition_range(DateTime(1950, 08, 31, 21), tz, UTC) == 2:2
        @test transition_range(DateTime(1950, 08, 31, 22), tz, UTC) == 2:2  # 00:00 TDT
        @test transition_range(DateTime(1950, 08, 31, 23), tz, UTC) == 2:2  # 01:00 TDT
        @test transition_range(DateTime(1950, 09, 01, 00), tz, UTC) == 3:3  # 00:00 TST
        @test transition_range(DateTime(1950, 09, 02, 00), tz, UTC) == 3:3  # 01:00 TST
        @test transition_range(DateTime(1950, 09, 03, 00), tz, UTC) == 3:3
    end
end

@testset "interpret (Vector)" begin
    # Test correct handling of ambiguity when converting vectors of `DateTime`s.
    # Start some hours before the critical point, end some hours afterwards
    # Critical points are defined in UTC
    t0s = Dict(
        "winter 2 summer" => DateTime(2023,03,26,0,0), # Change to summer time on March 26th --> should not be a problem, jump from 1:00 to 3:00
        "summer 2 winter" => DateTime(2023,10,29,0,0), # Change to winter time on October 29th --> now it gets interesting, 2:00 appears twice
    )
    dt = Minute(13) # use unusual increment to really test functionality
    function utc2local(utc_dts::AbstractVector{DateTime})
        utc_tzs = ZonedDateTime.(utc_dts, TimeZones.tz"UTC")
        local_tzs = astimezone.(utc_tzs, TimeZones.tz"Europe/Vienna")
        local_dts = DateTime.(local_tzs) # lose timezone information
        return local_dts, local_tzs
    end
    for (testcase, t0) in t0s
        for is_ascending in [true, false]
            @testset "$testcase $(is_ascending ? "ascending" : "descending")" begin
                # Create a vector of times that are potentially ambiguous, but sorted with a constant sampling time
                utc_dts = is_ascending ? (t0-Hour(3):dt:t0+Hour(3)) : (t0+Hour(3):-dt:t0-Hour(3))
                local_dts, local_tzs = utc2local(utc_dts)
                local_tzs_from_dts = interpret(local_dts, TimeZones.tz"Europe/Vienna", Local)
                @test all(local_tzs_from_dts .== local_tzs)
                @test all(diff(local_tzs_from_dts) .== (is_ascending ? dt : -dt))
            end
        end
    end
    # Border case: No context available, cannot resolve ambiguity
    utc_dts = [t0s["summer 2 winter"]]
    local_dts, local_tzs = utc2local(utc_dts)
    @test_throws AmbiguousTimeError interpret(local_dts, TimeZones.tz"Europe/Vienna", Local)

    utc_dts_sorted = t0s["summer 2 winter"] .+ (-Hour(3):Hour(1):Hour(3))
    # Non-constant sampling time, but sorted --> should be resolved
    utc_dts = utc_dts_sorted[[1,2,4,5,6,7]]
    local_dts, local_tzs = utc2local(utc_dts)
    local_tzs_from_dts = interpret(local_dts, TimeZones.tz"Europe/Vienna", Local)
    @test all(local_tzs_from_dts .== local_tzs)
    utc_dts = utc_dts_sorted[[7,5,4,3,2,1]]
    local_dts, local_tzs = utc2local(utc_dts)
    local_tzs_from_dts = interpret(local_dts, TimeZones.tz"Europe/Vienna", Local)
    @test all(local_tzs_from_dts .== local_tzs)
    # Non-sorted vector --> cannot resolve ambiguity at all
    utc_dts = utc_dts_sorted[[1,3,2,5,7,6,4]]
    local_dts, local_tzs = utc2local(utc_dts)
    @test_throws AmbiguousTimeError interpret(local_dts, TimeZones.tz"Europe/Vienna", Local)
end

# Contains both positive and negative UTC offsets and observes daylight saving time.
apia = first(compile("Pacific/Apia", tzdata["australasia"]))

ambiguous_pos = DateTime(2011,4,2,3)
non_existent_pos = DateTime(2011,9,24,3)
ambiguous_neg = DateTime(2012,4,1,3)
non_existent_neg = DateTime(2012,9,30,3)

@test_throws AmbiguousTimeError ZonedDateTime(ambiguous_pos, apia)
@test_throws NonExistentTimeError ZonedDateTime(non_existent_pos, apia)
@test_throws AmbiguousTimeError ZonedDateTime(ambiguous_neg, apia)
@test_throws NonExistentTimeError ZonedDateTime(non_existent_neg, apia)

@test isempty(TimeZones.shift_gap(ambiguous_pos, apia))
@test TimeZones.shift_gap(non_existent_pos, apia) == (
    ZonedDateTime(2011, 9, 24, 2, 59, 59, 999, apia),
    ZonedDateTime(2011, 9, 24, 4, apia),
)
@test isempty(TimeZones.shift_gap(ambiguous_neg, apia))
@test TimeZones.shift_gap(non_existent_neg, apia) == (
    ZonedDateTime(2012, 9, 30, 2, 59, 59, 999, apia),
    ZonedDateTime(2012, 9, 30, 4, apia),
)

# Valid local datetimes close to the non-existent hour should have no boundaries as are
# already valid.
@test isempty(TimeZones.shift_gap(non_existent_pos - Second(1), apia))
@test isempty(TimeZones.shift_gap(non_existent_pos + Hour(1), apia))
@test isempty(TimeZones.shift_gap(non_existent_neg - Second(1), apia))
@test isempty(TimeZones.shift_gap(non_existent_neg + Hour(1), apia))


# Create custom VariableTimeZones to test corner cases
zone = Dict{AbstractString,FixedTimeZone}()
zone["T+0"] = FixedTimeZone("T+0", 0)
zone["T+1"] = FixedTimeZone("T+1", 3600)
zone["T+2"] = FixedTimeZone("T+2", 7200)

# A time zone with a two hour gap
long = VariableTimeZone("Test/LongGap", [
    Transition(DateTime(1800,1,1,0), zone["T+1"])
    Transition(DateTime(1900,1,1,0), zone["T+0"])
    Transition(DateTime(1935,4,1,2), zone["T+2"])
])

# A time zone with an unnecessary transition that typically is hidden to the user
hidden = VariableTimeZone("Test/HiddenTransition", [
    Transition(DateTime(1800,1,1,0), zone["T+1"])
    Transition(DateTime(1900,1,1,0), zone["T+0"])
    Transition(DateTime(1935,4,1,2), zone["T+1"])  # The hidden transition
    Transition(DateTime(1935,4,1,2), zone["T+2"])
])

non_existent_1 = DateTime(1935,4,1,2)
non_existent_2 = DateTime(1935,4,1,3)

# Both "long" and "hidden" are identical for the following tests
for tz in (long, hidden)
    local tz
    boundaries = (
        ZonedDateTime(1935, 4, 1, 1, 59, 59, 999, tz),
        ZonedDateTime(1935, 4, 1, 4, tz),
    )

    @test_throws NonExistentTimeError ZonedDateTime(DateTime(0), tz)
    @test_throws NonExistentTimeError ZonedDateTime(non_existent_1, tz)
    @test_throws NonExistentTimeError ZonedDateTime(non_existent_2, tz)

    # Unhandled datetimes should not be treated as a gap
    @test isempty(TimeZones.shift_gap(DateTime(0), tz))

    @test TimeZones.shift_gap(non_existent_1, tz) == boundaries
    @test TimeZones.shift_gap(non_existent_2, tz) == boundaries
end


# Various DateTimes in Pacific/Apia
valid = DateTime(2013,1,1)
ambiguous = ambiguous_pos
non_existent = non_existent_pos

# first_valid/last_valid with a step
@test TimeZones.first_valid(valid, apia, Hour(1)) == ZonedDateTime(valid, apia)
@test TimeZones.last_valid(valid, apia, Hour(1)) == ZonedDateTime(valid, apia)

@test TimeZones.first_valid(non_existent, apia, Hour(1)) == ZonedDateTime(2011,9,24,4,apia)
@test TimeZones.last_valid(non_existent, apia, Hour(1)) == ZonedDateTime(2011,9,24,2,apia)

@test TimeZones.first_valid(ambiguous, apia, Hour(1)) == ZonedDateTime(ambiguous,apia,1)
@test TimeZones.last_valid(ambiguous, apia, Hour(1)) == ZonedDateTime(ambiguous,apia,2)

# first_valid/last_valid with no step
@test TimeZones.first_valid(valid, apia) == ZonedDateTime(valid, apia)
@test TimeZones.last_valid(valid, apia) == ZonedDateTime(valid, apia)

@test TimeZones.first_valid(non_existent, apia) == ZonedDateTime(2011,9,24,4,apia)
@test TimeZones.last_valid(non_existent, apia) == ZonedDateTime(2011,9,24,2,59,59,999,apia)

@test TimeZones.first_valid(ambiguous, apia) == ZonedDateTime(ambiguous,apia,1)
@test TimeZones.last_valid(ambiguous, apia) == ZonedDateTime(ambiguous,apia,2)

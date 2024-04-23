# Compare a local instant to a UTC transition instant by using the offset to make them both
# into local time. We could just as easily convert both of them into UTC time.
lt_local(local_dt::DateTime, t::Transition) = isless(local_dt, t.utc_datetime + t.zone.offset)
lt_local(t::Transition, local_dt::DateTime) = isless(t.utc_datetime + t.zone.offset, local_dt)

lt_utc(utc_dt::DateTime, t::Transition) = isless(utc_dt, t.utc_datetime)
lt_utc(t::Transition, utc_dt::DateTime) = isless(t.utc_datetime, utc_dt)

function transition_range(local_dt::DateTime, tz::VariableTimeZone, ::Type{Local})
    # To understand the logic in this function some background on transitions is needed:
    #
    # A transition (`t[i]`) is applicable to a given UTC instant that occurs on or after the
    # transition start (`t[i].utc_datetime`). The transition (`t[i]`) ends at the start of
    # the next transition in the list (`t[i + 1].utc_datetime`).
    #
    # Any UTC instant that occurs prior to the first transition (`t[1].utc_datetime`) has no
    # associated transitions. Any UTC instant that occurs on or after the last transition
    # (`t[end].utc_datetime`) is associated, at a minimum, with the last transition.

    # Determine the latest transition that applies to `local_dt`. If the `local_dt`
    # preceeds all transitions `finish` will be zero and produce the empty range `1:0`.
    finish = searchsortedlast(tz.transitions, local_dt, lt=lt_local)

    # Usually we'll begin by having `start` be larger than `finish` to create an empty
    # range by default. In the scenario where last transition applies to the `local_dt` we
    # can avoid a bounds by setting `start = finish`.
    len = length(tz.transitions)
    start = finish < len ? finish + 1 : len

    # To determine the first transition that applies to the `local_dt` we will work
    # backwards. Typically, this loop will only use single iteration as multiple iterations
    # only occur when local times are ambiguous.
    @inbounds for i in (start - 1):-1:1
        # Compute the end of the transition in local time. Note that this instant is not
        # included in the implicitly defined transition interval (known as right-open in
        # interval parlance).
        transition_end = tz.transitions[i + 1].utc_datetime + tz.transitions[i].zone.offset

        # If the end of the transition occurs after the `local_dt` then this transition
        # applies to the `local_dt`.
        if transition_end > local_dt
            start = i
        else
            break
        end
    end

    return start:finish
end

function transition_range(utc_dt::DateTime, tz::VariableTimeZone, ::Type{UTC})
    finish = searchsortedlast(tz.transitions, utc_dt, lt=lt_utc)
    start = max(finish, 1)
    return start:finish
end

"""
    transition_range(dt::DateTime, tz::VariableTimeZone, context::Type{Union{Local,UTC}}) -> UnitRange

Finds the indexes of the `tz` transitions which may be applicable for the `dt`. The given
DateTime is expected to be local to the time zone or in UTC as specified by `context`. Note
that UTC context will always return a range of length one.
"""
transition_range(::DateTime, ::VariableTimeZone, ::Type{Union{Local,UTC}})

function interpret(local_dt::DateTime, tz::VariableTimeZone, ::Type{Local})
    t = tz.transitions
    r = transition_range(local_dt, tz, Local)

    possible = (ZonedDateTime(local_dt - t[i].zone.offset, tz, t[i].zone) for i in r)
    return IndexableGenerator(possible)
end

function interpret(utc_dt::DateTime, tz::VariableTimeZone, ::Type{UTC})
    t = tz.transitions
    r = transition_range(utc_dt, tz, UTC)
    length(r) == 1 || error("Internal TimeZones error: A UTC DateTime should only have a single interpretation")

    possible = (ZonedDateTime(utc_dt, tz, t[i].zone) for i in r)
    return IndexableGenerator(possible)
end

"""
    interpret(dt::DateTime, tz::VariableTimeZone, context::Type{Union{Local,UTC}}) -> Array{ZonedDateTime}

Produces a list of possible `ZonedDateTime`s given a `DateTime` and `VariableTimeZone`.
The result will be returned in chronological order. Note that `DateTime`s in the local
context typically return 0-2 results while the UTC context will always return 1 result.
"""
interpret(::DateTime, ::VariableTimeZone, ::Type{Union{Local,UTC}})


"""
    interpret(local_dts::AbstractVector{Dates.DateTime}, tz::VariableTimeZone, context::Type{Union{Local,UTC}}) -> Vector{ZonedDateTime}

Convert a vector of `Dates.DateTime` into `TimeZones.ZonedDateTime` with the given timezone `tz`.

This method requires a vector of timestamps that are sorted (except for jumps backwards in time at, e.g., the change from summer time to winter time in CET)
and are sampled at 1 hour or less.
It recognizes these jump backwards in time and uses them to resolve the ambiguity in timestamps such as `Dates.DateTime(2023,10,29,2,10)` in CET, 
which can either be 0:00 or 1:00 UTC.
"""
function interpret(local_dts::AbstractVector{Dates.DateTime}, tz::VariableTimeZone, T::Type{<:Union{Local,UTC}}=Local)

    possibilities = interpret.(local_dts, Ref(tz), Ref(T))
    n_possibilities = length.(possibilities)
    is_ambiguous = n_possibilities .> 1
    !any(is_ambiguous) && (return first.(possibilities))

    any(n_possibilities .== 0) && throw(NonExistentTimeError(local_dts[findfirst(n_possibilities .== 0)], tz))

    # Cannot handle ambiguity with less than three values
    n_samples = length(local_dts)
    n_samples < 3 && throw(AmbiguousTimeError(local_dts[findfirst(is_ambiguous)], tz))
   
    idx_non_ambiguous = findall(.!is_ambiguous)
    local_tzs = Vector{ZonedDateTime}(undef, n_samples)
    local_tzs[idx_non_ambiguous] = first.(possibilities[idx_non_ambiguous])

    # Find ranges with ambiguity; TODO: Could be implemented more efficiently
    delta_is_ambiguous = diff(Int.(is_ambiguous))
    idx_begin_ambiguous = findall(delta_is_ambiguous .== 1) .+ 1
    is_ambiguous[1] && pushfirst!(idx_begin_ambiguous, 1)
    idx_end_ambiguous = findall(delta_is_ambiguous .== -1) # last ambiguous element
    is_ambiguous[end] && push!(idx_end_ambiguous, n_samples)
    @assert length(idx_begin_ambiguous) == length(idx_end_ambiguous)

    # Try to extrapolate from non-ambiguous data to find most probable resolution for ambiguity
    for i_ambiguous in eachindex(idx_begin_ambiguous)
        i_begin_ambiguous = idx_begin_ambiguous[i_ambiguous]
        i_end_ambiguous = idx_end_ambiguous[i_ambiguous]
        n_ambiguous_samples = i_end_ambiguous - i_begin_ambiguous + 1
        
        # Try to extrapolate surrounding data to check whether the data matches the expected values
        sample_period, expected_local_tzs, last_tz, next_tz = if i_begin_ambiguous > 2
            sample_period = local_dts[i_begin_ambiguous-1] - local_dts[i_begin_ambiguous-2]
            last_tz = local_tzs[i_begin_ambiguous-1]
            next_tz = if i_end_ambiguous < n_samples
                local_tzs[i_end_ambiguous+1]
            else
                nothing
            end
            sample_period, last_tz .+ (1:n_ambiguous_samples) .* sample_period, last_tz, next_tz
        elseif i_end_ambiguous < n_samples-1
            # interval starts at the beginning of data
            sample_period = local_dts[i_end_ambiguous+2] - local_dts[i_end_ambiguous+1]
            next_tz = local_tzs[i_end_ambiguous+1]
            sample_period, next_tz .- (n_ambiguous_samples:-1:1) .* sample_period, nothing, next_tz
        else
            # Missing context, cannot resolve ambiguity
            throw(AmbiguousTimeError(local_dts[i_begin_ambiguous], tz))
        end

        # if no information about order is available, we cannot resolve the ambiguity
        sample_period == Dates.Second(0) && throw(AmbiguousTimeError(local_dts[i_begin_ambiguous], tz))

        # Check for constant sample time --> if this is the case, we can be very sure of the resolution of the ambiguity
        has_constant_sample_time = true
        for i = 1:n_ambiguous_samples
            idx = i_begin_ambiguous+i-1
            # If the possibilities do not match expected data, we cannot resolve the ambiguity
            if !any(possibilities[idx] .== expected_local_tzs[i])
                has_constant_sample_time = false
                break
            end
            local_tzs[idx] = expected_local_tzs[i]
        end
        if !has_constant_sample_time
            # We could not determine the values from extrapolating the surrounding data; but maybe they are simply sorted?
            # We can only be sure if BOTH ambiguous options appear in the data
            # Otherwise we will throw since we cannot be completely sure that the ambiguity was correctly resolved!
            is_ascending = sample_period > Dates.Second(0)
            includes_jump = false
            for i = 1:n_ambiguous_samples
                idx = i_begin_ambiguous+i-1
                if is_ascending
                    # we expect to find consecutively increasing times
                    if isnothing(last_tz) # no context, start with the earliest option
                        local_tzs[idx] = first(possibilities[idx])
                        last_tz = local_tzs[idx]
                        continue
                    end
                    last(possibilities[idx]) > last_tz || throw(AmbiguousTimeError(local_dts[idx], tz))
                    # Start with earlier possibility, then later one
                    if first(possibilities[idx]) > last_tz # no jump backwards in time
                        local_tzs[idx] = first(possibilities[idx])
                    else
                        local_tzs[idx] = last(possibilities[idx])
                        includes_jump = true
                    end
                    last_tz = local_tzs[idx]
                else
                    # we expect to find consecutively decreasing times
                    if isnothing(last_tz) # no context, start with the later option
                        local_tzs[idx] = last(possibilities[idx])
                        last_tz = local_tzs[idx]
                        continue
                    end
                    first(possibilities[idx]) < last_tz || throw(AmbiguousTimeError(local_dts[idx], tz))
                    # Start with later possibility, then earlier one
                    if last(possibilities[idx]) < last_tz # no jump forward in time
                        local_tzs[idx] = last(possibilities[idx])
                    else
                        local_tzs[idx] = first(possibilities[idx])
                        includes_jump = true
                    end
                    last_tz = local_tzs[idx]
                end
            end

            # If we do not have two occurrences of an ambiguous time in a sorted list, then we cannot know which one we should pick
            !includes_jump && throw(AmbiguousTimeError(local_dts[i_begin_ambiguous], tz))

            # If we have more information, we must check whether the ascending / descending order is violated
            if !isnothing(next_tz)
                if is_ascending
                    last_tz < next_tz || throw(AmbiguousTimeError(local_dts[i_end_ambiguous], tz))
                else
                    last_tz > next_tz || throw(AmbiguousTimeError(local_dts[i_end_ambiguous], tz))
                end
            end
        end
    end
    return local_tzs
end

"""
    shift_gap(local_dt::DateTime, tz::VariableTimeZone) -> Tuple

Given a non-existent local `DateTime` in a `TimeZone` produces a tuple containing two valid
`ZonedDateTime`s that span the gap. Providing a valid local `DateTime` returns an empty
tuple. Note that this function does not support passing in a UTC `DateTime` since there are
no non-existent UTC `DateTime`s.

Aside: the function name refers to a period of invalid local time (gap) caused by daylight
saving time or offset changes (shift).
"""
function shift_gap(local_dt::DateTime, tz::VariableTimeZone)
    r = transition_range(local_dt, tz, Local)
    boundaries = if isempty(r) && last(r) > 0 # FIXME: This can't be right? !isempty? Does not seem to have been tested?
        t = tz.transitions
        i, j = last(r), first(r)  # Empty range has the indices we want but backwards
        tuple(
            ZonedDateTime(t[i + 1].utc_datetime - eps(local_dt), tz, t[i].zone),
            ZonedDateTime(t[j].utc_datetime, tz, t[j].zone),
        )
    else
        tuple()
    end

    return boundaries
end

"""
    first_valid(local_dt::DateTime, tz::VariableTimeZone, step::Period)

Construct a valid `ZonedDateTime` by adjusting the local `DateTime`. If the local `DateTime`
is non-existent then it will be adjusted using the `step` to be *after* the gap. When the
local `DateTime` is ambiguous the *first* ambiguous `DateTime` will be returned.
"""
function first_valid(local_dt::DateTime, tz::VariableTimeZone, step::Period)
    possible = interpret(local_dt, tz, Local)

    # Skip all non-existent local datetimes.
    while isempty(possible)
        local_dt += step
        possible = interpret(local_dt, tz, Local)
    end

    return first(possible)
end

"""
    last_valid(local_dt::DateTime, tz::VariableTimeZone, step::Period)

Construct a valid `ZonedDateTime` by adjusting the local `DateTime`. If the local `DateTime`
is non-existent then it will be adjusted using the `step` to be *before* the gap. When the
local `DateTime` is ambiguous the *last* ambiguous `DateTime` will be returned.
"""
function last_valid(local_dt::DateTime, tz::VariableTimeZone, step::Period)
    possible = interpret(local_dt, tz, Local)

    # Skip all non-existent local datetimes.
    while isempty(possible)
        local_dt -= step
        possible = interpret(local_dt, tz, Local)
    end

    return last(possible)
end

function first_valid(local_dt::DateTime, tz::VariableTimeZone)
    possible = interpret(local_dt, tz, Local)
    return isempty(possible) ? last(shift_gap(local_dt, tz)) : first(possible)
end

function last_valid(local_dt::DateTime, tz::VariableTimeZone)
    possible = interpret(local_dt, tz, Local)
    return isempty(possible) ? first(shift_gap(local_dt, tz)) : last(possible)
end

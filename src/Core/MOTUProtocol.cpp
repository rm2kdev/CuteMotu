#include "MOTUProtocol.hpp"
#include <limits.h>

namespace motu {
uint16_t readLE16(const uint8_t* p) { return uint16_t(p[0]) | uint16_t(p[1]) << 8; }
uint32_t readLE32(const uint8_t* p) {
    return uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24;
}
uint32_t readBE32(const uint8_t* p) {
    return uint32_t(p[3]) | uint32_t(p[2]) << 8 | uint32_t(p[1]) << 16 | uint32_t(p[0]) << 24;
}
void writeLE32(uint8_t* p, uint32_t v) { for (unsigned i = 0; i < 4; ++i) p[i] = uint8_t(v >> (i * 8)); }
const char* errorText(Error e) {
    switch (e) {
    case Error::none: return "ok";
    case Error::truncated: return "truncated data";
    case Error::malformed: return "malformed data";
    case Error::unsupported: return "unsupported device or layout";
    case Error::capacity: return "capacity exceeded";
    case Error::wrongSequence: return "unrelated sequence";
    case Error::wrongOperation: return "unrelated operation";
    case Error::wrongAddress: return "unrelated register";
    case Error::deviceStatus: return "device reported an error";
    }
    return "unknown error";
}
const Endpoint* Alternate::endpoint(uint8_t a) const {
    for (unsigned i = 0; i < endpointCount; ++i) if (endpoints[i].address == a) return &endpoints[i];
    return nullptr;
}
const Alternate* Configuration::alternate(uint8_t n) const {
    for (unsigned i = 0; i < alternateCount; ++i)
        if (alternates[i].interfaceNumber == 0 && alternates[i].number == n) return &alternates[i];
    return nullptr;
}
Error parseConfiguration(const uint8_t* data, size_t length, Configuration& result) {
    result = {};
    if (!data || length < 9) return Error::truncated;
    if (data[0] != 9 || data[1] != 2) return Error::malformed;
    const size_t total = readLE16(data + 2);
    if (total < 9) return Error::malformed;
    if (total > length) return Error::truncated;
    Configuration parsed{};
    parsed.totalBytes = uint16_t(total); parsed.interfaceCount = data[4]; parsed.value = data[5];
    Alternate* alt = nullptr;
    uint8_t expected = 0;
    for (size_t offset = 9; offset < total;) {
        if (total - offset < 2) return Error::truncated;
        const uint8_t* d = data + offset;
        const size_t n = d[0];
        if (n < 2) return Error::malformed;
        if (n > total - offset) return Error::truncated;
        if (d[1] == 4) {
            if (n < 9 || (alt && alt->endpointCount != expected)) return Error::malformed;
            if (parsed.alternateCount >= 16 || d[4] > 16) return Error::capacity;
            for (unsigned i = 0; i < parsed.alternateCount; ++i)
                if (parsed.alternates[i].interfaceNumber == d[2] && parsed.alternates[i].number == d[3]) return Error::malformed;
            alt = &parsed.alternates[parsed.alternateCount++];
            alt->interfaceNumber = d[2]; alt->number = d[3]; expected = d[4];
            alt->interfaceClass = d[5]; alt->subclass = d[6]; alt->protocol = d[7];
        } else if (d[1] == 5) {
            if (!alt || n < 7 || alt->endpointCount >= expected || alt->endpoint(d[2])) return Error::malformed;
            Endpoint e{d[2], d[3], d[6], readLE16(d + 4)};
            if (!(e.address & 0x0f) || (e.address & 0x70) || e.transactions() > 3 || !e.payloadBytes()) return Error::malformed;
            if ((e.transferType() == 1 || e.transferType() == 3) && (e.interval < 1 || e.interval > 16)) return Error::malformed;
            alt->endpoints[alt->endpointCount++] = e;
        } else if (d[1] == 2) return Error::malformed;
        offset += n;
    }
    if (!alt || alt->endpointCount != expected) return Error::malformed;
    result = parsed;
    return Error::none;
}
Error validate828x(const Configuration& c) {
    if (c.value != 1 || c.interfaceCount != 1 || c.alternateCount != 5) return Error::unsupported;
    for (unsigned n = 0; n < 5; ++n) {
        auto a = c.alternate(uint8_t(n));
        if (!a || a->interfaceClass != 0xff || a->subclass != 4 || a->protocol != 0xff || a->endpointCount != (n ? 5 : 2)) return Error::unsupported;
        const uint8_t controlEndpoints[2] = {controlOut, controlIn};
        for (uint8_t addr : controlEndpoints) {
            auto e = a->endpoint(addr);
            if (!e || e->attributes != 3 || e->maxPacket != 256 || e->interval != 4) return Error::unsupported;
        }
        if (n) {
            auto out = a->endpoint(audioOut), in = a->endpoint(audioIn), timing = a->endpoint(timingIn);
            const uint16_t outPacket = (n == 2 || n == 4) ? 0x0b00 : 0x03c0;
            const uint16_t inPacket = n >= 3 ? 0x0bc0 : 0x03c0;
            if (!out || !in || !timing || out->attributes != 1 || in->attributes != 1 || timing->attributes != 3 ||
                out->maxPacket != outPacket || in->maxPacket != inPacket || timing->maxPacket != 4 ||
                out->interval != 1 || in->interval != 1 || timing->interval != 1) return Error::unsupported;
        }
    }
    return Error::none;
}
Command readRegister(uint8_t seq, uint32_t address) {
    Command c{}; c.length = 6; c.bytes[0] = seq; c.bytes[1] = 4; writeLE32(c.bytes + 2, address); return c;
}
Command writeRegister(uint8_t seq, uint32_t address, uint32_t value) {
    Command c{}; c.length = 12; c.bytes[0] = seq;
    writeLE32(c.bytes + 4, address); writeLE32(c.bytes + 8, value); return c;
}
Error parseReply(const uint8_t* p, size_t n, Reply& reply) {
    reply = {};
    if (!p || n < 3) return Error::truncated;
    if (p[1] != 6 && p[1] != 2) return Error::wrongOperation;
    const size_t expected = p[1] == 6 ? 12 : 7;
    if (n < expected) return Error::truncated;
    if (n != expected) return Error::malformed;
    reply.sequence = p[0]; reply.operation = p[1]; reply.status = p[2];
    reply.address = readLE32(p + (p[1] == 6 ? 4 : 3));
    if (p[1] == 6) reply.value = readLE32(p + 8);
    return Error::none;
}
bool RegisterReplyScanner::feed(const uint8_t* p,size_t n,Reply& result) {
    result={};
    if(!p || !sequence_ || (operation_!=2 && operation_!=6))return false;
    const size_t length=operation_==6?12:7;
    for(size_t i=0;i<n;i++) {
        bytes_[used_++]=p[i];
        if(used_<length)continue;
        Reply candidate{};
        if(bytes_[0]==sequence_ && bytes_[1]==operation_ &&
           (operation_!=6 || bytes_[3]==0) && parseReply(bytes_,length,candidate)==Error::none &&
           candidate.address==address_) {result=candidate;used_=0;return true;}
        for(size_t j=1;j<used_;j++)bytes_[j-1]=bytes_[j];
        used_--;
    }
    return false;
}
Error matchReadReply(const Reply& r, uint8_t seq, uint32_t address) {
    if (r.sequence != seq) return Error::wrongSequence;
    if (r.operation != 6) return Error::wrongOperation;
    if (r.address != address) return Error::wrongAddress;
    // The status byte's success convention is inferred from the installed
    // driver's zero/non-zero test. This still needs a live captured reply.
    return r.status ? Error::deviceStatus : Error::none;
}
bool ReadTransaction::begin(uint8_t seq, uint32_t address, uint64_t now, uint64_t timeout) {
    if (state_ == State::waiting || !timeout || timeout > UINT64_MAX - now) return false;
    sequence_ = seq; address_ = address; deadline_ = now + timeout; value_ = 0; state_ = State::waiting; return true;
}
Error ReadTransaction::receive(const uint8_t* p, size_t n) {
    if (state_ != State::waiting) return Error::unsupported;
    Reply r{}; auto e = parseReply(p, n, r);
    if (e != Error::none) return e;
    e = matchReadReply(r, sequence_, address_);
    if (e == Error::deviceStatus) state_ = State::failed;
    if (e == Error::none) { value_ = r.value; state_ = State::complete; }
    return e;
}
bool ReadTransaction::expire(uint64_t now) {
    if (state_ == State::waiting && now >= deadline_) { state_ = State::failed; return true; }
    return false;
}
void ReadTransaction::cancel() { state_ = State::idle; value_ = 0; }
Error validateLayout(const AudioLayout& l) {
    if (!l.channels || l.channels > 64 || !l.frameBytes || l.frameBytes > 4096) return Error::unsupported;
    if (uint32_t(l.pcmOffset) + uint32_t(l.channels) * 3 > l.frameBytes || uint32_t(l.timestampOffset) + 4 > l.frameBytes) return Error::malformed;
    if (l.timestampOffset < l.pcmOffset + l.channels * 3 && l.timestampOffset + 4 > l.pcmOffset) return Error::malformed;
    return Error::none;
}
int32_t decode24(const uint8_t* p, bool be) {
    const uint32_t u = be ? (uint32_t(p[0]) << 16 | uint32_t(p[1]) << 8 | p[2]) : (uint32_t(p[2]) << 16 | uint32_t(p[1]) << 8 | p[0]);
    return (u & 0x800000) ? int32_t(u) - 0x1000000 : int32_t(u);
}
void encode24(int32_t s, uint8_t* p, bool be) {
    if (s > 8388607) s = 8388607;
    if (s < -8388608) s = -8388608;
    uint32_t u = uint32_t(s);
    for (unsigned i = 0; i < 3; ++i) p[be ? 2 - i : i] = uint8_t(u >> (8 * i));
}
Error decodeAudioPacket(const uint8_t* p, size_t n, const AudioLayout& l, int32_t* samples, size_t cap, size_t& frames) {
    frames = 0;
    auto e = validateLayout(l); if (e != Error::none) return e;
    if ((!p && n) || n % l.frameBytes) return Error::malformed;
    size_t count = n / l.frameBytes;
    if (count > cap / l.channels || (count && !samples)) return Error::capacity;
    for (size_t f = 0; f < count; ++f)
        for (unsigned c = 0; c < l.channels; ++c)
            samples[f * l.channels + c] = decode24(p + f * l.frameBytes + l.pcmOffset + c * 3, l.bigEndianPCM);
    frames = count; return Error::none;
}
bool TimestampUnwrapper::push(uint32_t raw, uint64_t& extended) {
    if (!valid_) { last_ = raw; total_ = raw; valid_ = true; extended = total_; return true; }
    uint32_t delta = raw - last_;
    if (delta >= 0x80000000u || delta > UINT64_MAX - total_) return false;
    total_ += delta; last_ = raw; extended = total_; return true;
}
}

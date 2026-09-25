package poc.ring;

import io.netty.buffer.ByteBuf;
import io.netty.buffer.ByteBufAllocator;
import io.netty.buffer.UnpooledByteBufAllocator;
import io.netty.channel.uring.IoUringAdaptiveBufferRingAllocator;
import io.netty.channel.uring.IoUringBufferRingAllocator;

/**
 * The candidates of RESULTS.md section 7, built the same way for every benchmark in this package, so
 * the owner-thread and the foreign-release runs cannot end up measuring two different objects.
 * The ring shape is netty's default for these servers: 64 entries, 8 KiB chunk, slab depth 4.
 */
final class RingAllocs {
    static final int ENTRIES = 64;
    static final int CHUNK = 8192;
    static final int DEPTH = 4;
    /** Bytes the "kernel" wrote into the buffer: one TCP segment's payload over Ethernet. */
    static final int READ = 1448;

    private RingAllocs() { }

    static IoUringBufferRingAllocator build(String name) {
        switch (name) {
            case "adaptive":
                return new FixedRing(new io.netty.buffer.AdaptiveByteBufAllocator(), CHUNK);
            case "builtinadaptive":
                return new IoUringAdaptiveBufferRingAllocator(ByteBufAllocator.DEFAULT);
            case "unpooled":
                return new FixedRing(UnpooledByteBufAllocator.DEFAULT, CHUNK);
            case "slab":
                return new RegisteredSlabBufferRingAllocator(ENTRIES, CHUNK, DEPTH);
            case "slab2":       return slabV2("slab2", true, false, false);
            case "slab2fixed":  return slabV2("slab2fixed", false, false, false);
            case "slab3":       return slabV2("slab3", true, true, false);
            case "slab3fixed":  return slabV2("slab3fixed", false, true, false);
            case "slab3huge":   return slabV2("slab3huge", true, true, true);
            default:
                throw new IllegalArgumentException(name);
        }
    }

    static SlabV2BufferRingAllocator slabV2(String name, boolean adaptiveSlot, boolean loopLocal,
                                           boolean align2M) {
        return new SlabV2BufferRingAllocator(name, ENTRIES, CHUNK, DEPTH, adaptiveSlot, loopLocal,
                align2M, true, 32 << 20, 1024, 65536, false,
                1 << 14, 1 << 16, 1024, 8, true, UnpooledByteBufAllocator.DEFAULT);
    }

    /** What {@code Transports.FixedSizeRingAllocator} is: one directBuffer(size) per re-add. */
    static final class FixedRing implements IoUringBufferRingAllocator {
        private final ByteBufAllocator a;
        private final int size;
        FixedRing(ByteBufAllocator a, int size) { this.a = a; this.size = size; }
        @Override public ByteBuf allocate() { return a.directBuffer(size); }
        @Override public void lastBytesRead(int attempted, int actual) { }
    }
}

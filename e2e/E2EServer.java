import io.netty.bootstrap.ServerBootstrap;
import io.netty.buffer.ByteBufAllocator;
import io.netty.channel.*;
import io.netty.channel.nio.NioIoHandler;
import io.netty.channel.socket.nio.NioServerSocketChannel;

/** E2E launcher: same example pipelines as netty's HttpSnoopServer (h1) / Http2Server (h2), allocator chosen by arg. */
public class E2EServer {
    public static void main(String[] args) throws Exception {
        String alloc = args[0], proto = args[1]; int port = Integer.parseInt(args[2]); int loops = Integer.parseInt(args[3]);
        ByteBufAllocator allocator;
        switch (alloc) {
            case "adaptive": allocator = new io.netty.buffer.AdaptiveByteBufAllocator(); break;
            case "arena": allocator = new io.netty.buffer.CycleArenaAllocator(); break;
            case "mimalloc": allocator = new io.github.neoionet.netty.mimalloc.MiByteBufAllocator(); break;
            default: throw new IllegalArgumentException(alloc);
        }
        if ("arena".equals(alloc)) {
            Runtime.getRuntime().addShutdownHook(new Thread(() -> { System.out.println(io.netty.buffer.CycleArenaAllocator.counters()); System.out.flush(); }));
        }
        EventLoopGroup boss = new MultiThreadIoEventLoopGroup(1, NioIoHandler.newFactory());
        EventLoopGroup workers = new MultiThreadIoEventLoopGroup(loops, NioIoHandler.newFactory());
        ChannelHandler init = "h2".equals(proto)
                ? new io.netty.example.http2.helloworld.server.Http2ServerInitializer(null)
                : new io.netty.example.http.snoop.HttpSnoopServerInitializer(null);
        ServerBootstrap b = new ServerBootstrap();
        b.group(boss, workers).channel(NioServerSocketChannel.class)
         .option(ChannelOption.ALLOCATOR, allocator).childOption(ChannelOption.ALLOCATOR, allocator)
         .childHandler(init);
        Channel ch = b.bind(port).sync().channel();
        System.out.println("READY " + alloc + " " + proto + " " + port + " loops=" + loops);
        ch.closeFuture().sync();
    }
}

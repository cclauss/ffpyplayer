
__all__ = ('MediaPlayer', )

include '../includes/ff_consts.pxi'
include "../includes/inline_funcs.pxi"

cdef extern from "Python.h":
    void PyEval_InitThreads()

cdef extern from "math.h" nogil:
    double NAN
    int isnan(double x)

cdef extern from "string.h" nogil:
    void * memset(void *, int, size_t)

from ffpyplayer.threading cimport MTGenerator, SDL_MT, Py_MT, MTThread, MTMutex
from ffpyplayer.player.queue cimport FFPacketQueue
from ffpyplayer.player.core cimport VideoState, VideoSettings
from ffpyplayer.pic cimport Image
from libc.stdio cimport printf
from cpython.ref cimport PyObject

import ffpyplayer.tools  # required to init ffmpeg
from ffpyplayer.tools import initialize_sdl_aud, encode_to_bytes
from copy import deepcopy


cdef inline void *grow_array(void *array, int elem_size, int *size, int new_size) nogil:
    cdef uint8_t *tmp
    if new_size >= INT_MAX / elem_size:
        return NULL

    if size[0] < new_size:
        tmp  = <uint8_t *>av_realloc_array(array, new_size, elem_size)
        if tmp == NULL:
            return NULL

        memset(tmp + size[0] * elem_size, 0, (new_size - size[0]) * elem_size)
        size[0] = new_size
        return tmp
    return array


cdef class MediaPlayer(object):
    '''An FFmpeg based media player.

    Was originally ported from FFplay. Most options offered in FFplay is
    also available here.

    The class provides a player interface to a media file. Video components
    of the file are returned with :meth:`get_frame`. Audio is played directly
    using SDL. And subtitles are acquired either through the callback function
    (text subtitles only), or are overlaid directly using the subtitle filter.

    .. note::

        All strings that are passed to the program, e.g. ``filename`` will first be
        internally encoded using utf-8 before handing off to FFmpeg.

    :Parameters:

        `filename`: str
            The filename or url of the media object. This can be physical files,
            remote files or even webcam name's e.g. for direct show or Video4Linux
            webcams. The ``f`` specifier in ``ff_opts`` can be used to indicate the
            format needed to open the file (e.g. dshow).
        `callback`: Function or ref to function or None
            A function, which if not None will be called when a internal thread quits,
            when eof is reached (as determined by whichever is the main ``sync`` stream,
            audio or video), or when text subtitles are available. In future version it
            may be extended.

            The function takes two parameters, ``selector``, and ``value``.
            ``selector`` can be one of:

            `eof`: When eof is reached. ``value`` is the empty string.
            `display_sub`:
                When a new subtitle string is available. ``value`` will be a
                5-tuple of the form ``(text, fmt, pts, start, end)``. Where

                `text`: is the unicode text
                `fmt`: is the subtitle format e.g. 'ass'
                `pts`: is the timestamp of the text
                `start`: is the time in video time when to start displaying the text
                `end`: is the time in video time when to end displaying the text

            `exceptions or thread exits`:
                In case of an exception by the internal audio, video, subtitle, or read threads,
                or when these threads exit, it is called with a ``value`` of the error message
                or an empty string when an error is not available.

                The ``selector`` will be one of
                ``audio:error``, ``audio:exit``, ``video:error``, ``video:exit``,
                ``subtitle:error``, ``subtitle:exit``, ``read:error``, or ``read:exit``
                indicating which thread called and why.

            .. warning::

                This functions gets called from a second internal thread.

        `thread_lib`: str
            The threading library to use internally. Can be one of 'SDL' or 'python'.

            .. warning::

                If the python threading library is used, care must be taken to delete
                the player before exiting python, otherwise it may hang. The reason is
                that the internal threads are created as non-daemon, consequently, when the
                python main thread exits, the internal threads will keep python alive.
                By deleting the player directly, the internal threads will be shut down
                before python exits.

        `audio_sink`: str
            Currently it must be 'SDL'. Defaults to 'SDL'.
        `lib_opts`: dict
            A dictionary of options that will be passed to the ffmpeg libraries,
            codecs, sws, swr, and formats when opening them. This accepts most of the
            options that can be passed to FFplay. Examples are "threads":"auto",
            "lowres":"1" etc. Both the keywords and values must be strings.
            See :ref:`examples` for `lib_opts` usage examples.
        `ff_opts`: dict
            A dictionary with options for the player. Following are
            the available options. Note, many options have identical names and meaning
            as in the FFplay options: www.ffmpeg.org/ffplay.html :

            `paused`: bool
                If True, the player will be in a paused state after creation, otherwise,
                it will immediately start playing. Defaults to False.
            `cpuflags`: str
                Similar to ffplay
            `max_alloc: int
                Set the maximum size that may me allocated in one block.
            `infbuf`: bool
                If True, do not limit the input buffer size and read as much data as possible
                from the input as soon as possible. Enabled by default for realtime streams,
                where data may be dropped if not read in time. Use this option to enable
                infinite buffers for all inputs.
            `framedrop`: bool
                Drop video frames if video is out of sync. Enabled by default if the master
                clock (``sync``) is not set to video. Use this option to enable/disable frame
                dropping for all master clock sources.
            `loop`: int
                Loops movie playback <number> times. 0 means forever. Defaults to 1.
            `autoexit`: bool
                If True, the player stops on eof. Defaults to False.
            `lowres`: int
                low resolution decoding, 1-> 1/2 size, 2->1/4 size, defaults to zero.
            `drp`: int
                let decoder reorder pts 0=off 1=on -1=auto. Defaults to 0.
            `genpts`: bool
                Generate missing pts even if it requires parsing future frames, defaults to False.
            `fast: bool
                Enable non-spec-compliant optimizations, defaults to False.
            `stats`: bool
                Print several playback statistics, in particular show the stream duration,
                the codec parameters, the current position in the stream and the audio/video
                synchronisation drift. Defaults to False.
            `pixel_format`: str
                Sets the pixel format. Note, this sets the format of the input file. For the output
                format see ``out_fmt``.
            `t`: float
                Play only ``t`` seconds of the audio/video. Defaults to the full audio/video.
            `ss`: float
                Seek to pos ``ss`` into the file when starting. Note that in most formats it is not
                possible to seek exactly, so it will seek to the nearest seek point to ``ss``.
                Defaults to the start of the file.
            `sync`: str
                Set the master clock to audio, video, or external (ext). Default is audio.
                The master clock is used to control audio-video synchronization. Most
                media players use audio as master clock, but in some cases (streaming or
                high quality broadcast) it is necessary to change that. Also, setting
                it to video can ensure the reproducibility of timestamps of video frames.
            `acodec, vcodec, and scodec`: str
                Forces a specific audio, video, and/or subtitle decoder. Defaults to None.
            `ast`: str
                Select the desired audio stream. If this option is not specified, the "best" audio
                stream is selected in the program of the already selected video stream.
                See https://ffmpeg.org/ffplay.html#Stream-specifiers-1 for the format.
            `vst`: str
                Select the desired video stream. If this option is not specified, the "best" video
                stream is selected.
                See https://ffmpeg.org/ffplay.html#Stream-specifiers-1 for the format.
            `sst`: str
                Select the desired subtitle stream. If this option is not specified, the "best" audio
                stream is selected in the program of the already selected video or audio stream.
                See https://ffmpeg.org/ffplay.html#Stream-specifiers-1 for the format.
            `an`: bool
                Disable audio. Default to False.
            `vn`: bool
                Disable video. Default to False.
            `sn`: bool
                Disable subtitle. Default to False.
            `f`: str
                Force the format to open the file with. E.g. dshow for webcams on windows.
                See :ref:`dshow-example` for an example. Defaults to none specified.
            `vf`: str or list of strings
                The filtergraph(s) used to filter the video stream. A filtergraph is applied to the
                stream, and must have a single video input and a single video output.
                In the filtergraph, the input is associated to the label in, and the output
                to the label out. See the ffmpeg-filters manual for more information
                about the filtergraph syntax.

                Examples are 'crop=100:100' to crop, 'vflip' to flip horizontally, 'subtitles=filename'
                to overlay subtitles from another media or text file etc. If a list of filters is
                specified, :meth:`select_video_filter` can be used to select the desired filter.

                CONFIG_AVFILTER must be True (the default) when compiling in order to use this.
                Defaults to no filters.
            `af`: str
                Similar to ``vf``. However, unlike ``vf``, ``af`` only accepts a single string
                filter and not a list of filters.
            `x`: int
                The desired width of the output frames returned by :meth:`get_frame`. Accepts the
                same values as the width parameter of :meth:`set_size`.
            `y`: int
                The desired height of the output frames returned by :meth:`get_frame`. Accepts the
                same values as the height parameter of :meth:`set_size`.

                CONFIG_AVFILTER must be True (the default) when compiling in order to use this.
                Defaults to 0.
            `out_fmt`: str
                The desired pixel format for the data returned by :meth:`get_frame`. Accepts
                the same value as :meth:`set_output_pix_fmt` and can be
                one of :attr:`ffpyplayer.tools.pix_fmts`. Defaults to rgb24.
            `autorotate`: bool
                Whether to automatically rotate the video according to presentation metadata.
                Defaults to True.

    For example, a simple player::

        from ffpyplayer.player import MediaPlayer
        player = MediaPlayer(filename)
        while 1:
            frame, val = player.get_frame()
            if val == 'eof':
                break
            elif frame is None:
                time.sleep(0.01)
            else:
                img, t = frame
                print val, t, img.get_pixel_format(), img.get_buffer_size()
                time.sleep(val)
        # which prints
        0.0 0.0 rgb24 (929280, 0, 0, 0)
        0.0 0.0611284 rgb24 (929280, 0, 0, 0)
        0.0411274433136 0.1222568 rgb24 (929280, 0, 0, 0)
        0.122380971909 0.1833852 rgb24 (929280, 0, 0, 0)
        0.121630907059 0.2445136 rgb24 (929280, 0, 0, 0)
        ...

    See also :ref:`examples`.

    .. warning::

        Most of the methods of this class are not thread safe. That is, they
        should not be called from different threads for the same instance
        without protecting them.
    '''

    def __cinit__(self, filename, callback=None, ff_opts={},
                  thread_lib='SDL', audio_sink='SDL', lib_opts={}, **kargs):
        cdef unsigned flags
        cdef VideoSettings *settings = &self.settings
        cdef AVPixelFormat out_fmt
        cdef int res, paused
        cdef const char* cy_str
        kargs.pop('loglevel', None)
        ff_opts = self.ff_opts = encode_to_bytes(deepcopy(ff_opts))
        lib_opts = encode_to_bytes(deepcopy(lib_opts))
        kargs = encode_to_bytes(deepcopy(kargs))
        filename = encode_to_bytes(filename)

        self.is_closed = 0
        memset(&self.settings, 0, sizeof(VideoSettings))
        self.ivs = None
        PyEval_InitThreads()

        av_dict_set(&settings.sws_dict, b"flags", b"bicubic", 0)
        # set x, or y to -1 to preserve pixel ratio
        settings.screen_width  = ff_opts['x'] if 'x' in ff_opts else 0
        settings.screen_height = ff_opts['y'] if 'y' in ff_opts else 0
        if not CONFIG_AVFILTER and (settings.screen_width or settings.screen_height):
            raise Exception('You can only set the screen size when avfilter is enabled.')
        settings.audio_disable = bool(ff_opts['an']) if 'an' in ff_opts else 0
        settings.video_disable = bool(ff_opts['vn']) if 'vn' in ff_opts else 0
        settings.subtitle_disable = bool(ff_opts['sn']) if 'sn' in ff_opts else 0

        settings.wanted_stream_spec[<int>AVMEDIA_TYPE_AUDIO] = \
        settings.wanted_stream_spec[<int>AVMEDIA_TYPE_VIDEO] = \
        settings.wanted_stream_spec[<int>AVMEDIA_TYPE_SUBTITLE] = NULL

        if 'ast' in ff_opts:
            cy_str = ff_opts['ast']
            settings.wanted_stream_spec[<int>AVMEDIA_TYPE_AUDIO] =  cy_str
        if 'vst' in ff_opts:
            cy_str = ff_opts['vst']
            settings.wanted_stream_spec[<int>AVMEDIA_TYPE_VIDEO] =  cy_str
        if 'sst' in ff_opts:
            cy_str = ff_opts['sst']
            settings.wanted_stream_spec[<int>AVMEDIA_TYPE_SUBTITLE] =  cy_str
        settings.start_time = ff_opts['ss'] * 1000000 if 'ss' in ff_opts else AV_NOPTS_VALUE
        settings.duration = ff_opts['t'] * 1000000 if 't' in ff_opts else AV_NOPTS_VALUE
        settings.autorotate = bool(ff_opts.get('autorotate', 1))
        settings.seek_by_bytes = -1
        settings.file_iformat = NULL
        if 'f' in ff_opts:
            settings.file_iformat = av_find_input_format(ff_opts['f'])
            if settings.file_iformat == NULL:
                raise ValueError('Unknown input format: %s.' % ff_opts['f'])
        if 'pixel_format' in ff_opts:
            av_dict_set(<AVDictionary **>&settings.format_opts, "pixel_format", ff_opts['pixel_format'], 0)
        settings.show_status = bool(ff_opts['stats']) if 'stats' in ff_opts else 0
        settings.fast = bool(ff_opts['fast']) if 'fast' in ff_opts else 0
        settings.genpts = bool(ff_opts['genpts']) if 'genpts' in ff_opts else 0
        settings.decoder_reorder_pts = -1
        if 'drp' in ff_opts:
            val = ff_opts['drp']
            if val != 1 and val != 0 and val != -1:
                raise ValueError('Invalid drp option value.')
            settings.decoder_reorder_pts = val
        settings.lowres = ff_opts['lowres'] if 'lowres' in ff_opts else 0
        settings.av_sync_type = AV_SYNC_AUDIO_MASTER
        settings.audio_volume = SDL_MIX_MAXVOLUME
        if 'sync' in ff_opts:
            val = ff_opts['sync']
            if val == 'audio':
                settings.av_sync_type = AV_SYNC_AUDIO_MASTER
            elif val == 'video':
                settings.av_sync_type = AV_SYNC_VIDEO_MASTER
            elif val == 'ext':
                settings.av_sync_type = AV_SYNC_EXTERNAL_CLOCK
            else:
                raise ValueError('Invalid sync option value.')
        settings.autoexit = bool(ff_opts['autoexit']) if 'autoexit' in ff_opts else 0
        settings.loop = ff_opts['loop'] if 'loop' in ff_opts else 1
        settings.framedrop = bool(ff_opts['framedrop']) if 'framedrop' in ff_opts else -1
        # -1 means not infinite, not respected if real time.
        settings.infinite_buffer = 1 if 'infbuf' in ff_opts and ff_opts['infbuf'] else -1

        IF CONFIG_AVFILTER:
            if 'vf' in ff_opts:
                vfilters = ff_opts['vf']
                if isinstance(vfilters, basestring):
                    vfilters = [vfilters]
                for vfilt in vfilters:
                    cy_str = vfilt
                    settings.vfilters_list = <const char **>grow_array(
                        settings.vfilters_list, sizeof(settings.vfilters_list[0]),
                        &settings.nb_vfilters, settings.nb_vfilters + 1)
                    settings.vfilters_list[settings.nb_vfilters - 1] = cy_str

            settings.afilters = NULL
            if 'af' in ff_opts:
                settings.afilters = ff_opts['af']
            settings.avfilters = NULL
            if 'avf' in ff_opts:
                settings.avfilters = ff_opts['avf']
        settings.audio_codec_name = NULL
        if 'acodec' in ff_opts:
            settings.audio_codec_name = ff_opts['acodec']
        settings.video_codec_name = NULL
        if 'vcodec' in ff_opts:
            settings.video_codec_name = ff_opts['vcodec']
        settings.subtitle_codec_name = NULL
        if 'scodec' in ff_opts:
            settings.subtitle_codec_name = ff_opts['scodec']
        if 'max_alloc' in ff_opts:
            av_max_alloc(ff_opts['max_alloc'])
        if 'cpuflags' in ff_opts:
            flags = av_get_cpu_flags()
            if av_parse_cpu_caps(&flags, ff_opts['cpuflags']) < 0:
                raise ValueError('Invalid cpuflags option value.')
            av_force_cpu_flags(flags)

        for k, v in lib_opts.iteritems():
            if opt_default(
                    k, v, NULL, &settings.sws_dict, &settings.swr_opts,
                    &settings.resample_opts, &settings.format_opts,
                    &self.settings.codec_opts) < 0:
                raise Exception('library option %s: %s not found' % (k, v))

        # filename can start with pipe:
        settings.input_filename = av_strdup(<char *>filename)
        if settings.input_filename == NULL:
            raise MemoryError()
        if thread_lib == 'SDL':
            if not CONFIG_SDL:
                raise Exception('FFPyPlayer extension not compiled with SDL support.')
            self.mt_gen = MTGenerator(SDL_MT)
        elif thread_lib == 'python':
            self.mt_gen = MTGenerator(Py_MT)
        else:
            raise Exception('Thread library parameter not recognized.')

        settings.audio_sdl = audio_sink == 'SDL'
        if audio_sink != 'SDL':
            raise Exception('Audio sink "{}" not recognized'.format(audio_sink))
        if callback is not None and not callable(callback):
            raise Exception('Video sink parameter not recognized.')

        if 'out_fmt' in ff_opts:
            out_fmt = av_get_pix_fmt(ff_opts['out_fmt'])
        else:
            out_fmt = av_get_pix_fmt(b'rgb24')
        if out_fmt == AV_PIX_FMT_NONE:
            raise Exception('Unrecognized output pixel format.')

        if not settings.audio_disable:
            initialize_sdl_aud()

        self.next_image = Image.__new__(Image, no_create=True)
        self.ivs = VideoState(callback)
        paused = ff_opts.get('paused', False)
        with nogil:
            self.ivs.cInit(self.mt_gen, settings, paused, out_fmt)

    def __dealloc__(self):
        self.close_player()

    cpdef close_player(self):
        '''Closes the player and all resources.

        .. warning::

            After calling this method, calling any other class method on this instance may
            result in a crash or program corruption.
        '''
        cdef const char *empty = b''
        if self.is_closed:
            return
        self.is_closed = 1

        #XXX: cquit has to be called, otherwise the read_thread never exitsts.
        # probably some circular referencing somewhere (in event_loop)
        if self.ivs:
            with nogil:
                self.ivs.cquit()
        self.ivs = None

        av_dict_free(&self.settings.format_opts)
        av_dict_free(&self.settings.resample_opts)
        av_dict_free(&self.settings.codec_opts)
        av_dict_free(&self.settings.swr_opts)
        av_dict_free(&self.settings.sws_dict)
        IF CONFIG_AVFILTER:
            av_freep(&self.settings.vfilters_list)
        # avformat_network_deinit()
        av_free(self.settings.input_filename)
        if self.settings.show_status:
            av_log(NULL, AV_LOG_INFO, b"\n")
        #SDL_Quit()
        av_log(NULL, AV_LOG_QUIET, b"%s", empty)

    def get_frame(self, force_refresh=False, show=True, *args):
        '''Retrieves the next available frame if ready.

        The frame is returned as a :class:`ffpyplayer.pic.Image`. If CONFIG_AVFILTER
        is True when compiling, or if the video pixel format is the same as the
        output pixel format, the Image returned is just a new reference to the internal
        buffers and no copying occurs (see :class:`ffpyplayer.pic.Image`), otherwise
        the buffers are newly created and copied.

        :Parameters:

            `force_refresh`: bool
                If True, a new instance of the last frame will be returned again.
                Defaults to False.
            `show`: bool
                If True a image is returned as normal, if False, no image will be
                returned, even when one is available. Can be useful if we just need
                the timestamps or when ``force_refresh`` to just get the timestamps.
                Defaults to True.

        :returns:

            `A 2-tuple of (frame, val)` where
                `frame`: is None or a 2-tuple
                `val`: is either 'paused', 'eof', or a float

            If ``val`` is either ``'paused'`` or ``'eof'`` then ``frame`` is None.

            Otherwise, if ``frame`` is not None, ``val`` is the realtime time from now
            one should wait before displaying this frame to the user to achieve a play
            rate of 1.0.

            Finally, if ``frame`` is not None then it's a 2-tuple of ``(image, pts)`` where:

                `image`: The :class:`ffpyplayer.pic.Image` instance containing
                    the frame. The size of the image can change because the output
                    can be resized dynamically (see :meth:`set_size`). If `show` was
                    False, it will be None.
                `pts`: The presentation timestamp of this frame. This is the time
                    when the frame should be displayed to the user in video time (i.e.
                    not realtime).

        .. note::

            The audio plays at a normal play rate, independent of when and if
            this function is called. Therefore, 'eof' will only be received when
            the audio is complete, even if all the frames have been read (unless
            audio is disabled or sync is set to video). I.e. a None frame will
            be sent after all the frames have been read until eof.

        For example, playing as soon as frames are read::

            >>> while 1:
            ...     frame, val = player.get_frame()
            ...     if val == 'eof':
            ...         break
            ...     elif frame is None:
            ...         time.sleep(0.01)
            ...         print 'not ready'
            ...     else:
            ...         img, t = frame
            ...         print val, t, img
            not ready
            0.0 0.0 <ffpyplayer.pic.Image object at 0x023D17B0>
            not ready
            0.0351264476776 0.0611284 <ffpyplayer.pic.Image object at 0x023D1828>
            0.096254825592 0.1222568 <ffpyplayer.pic.Image object at 0x02411800>
            not ready
            0.208511352539 0.1833852 <ffpyplayer.pic.Image object at 0x02411B70>

        vs displaying frames at their proper times::

            >>> while 1:
            ...     frame, val = player.get_frame()
            ...     if val == 'eof':
            ...         break
            ...     elif frame is None:
            ...         time.sleep(0.01)
            ...         print 'not ready'
            ...     else:
            ...         img, t = frame
            ...         print val, t, img
            ...         time.sleep(val)
            not ready
            0.0 0.0 <ffpyplayer.pic.Image object at 0x02411800>
            not ready
            0.0351274013519 0.0611284 <ffpyplayer.pic.Image object at 0x02411878>
            0.0602538585663 0.1222568 <ffpyplayer.pic.Image object at 0x024118A0>
            0.122507572174 0.1833852 <ffpyplayer.pic.Image object at 0x024118C8>
            ...
            0.0607514381409 1.222568 <ffpyplayer.pic.Image object at 0x02411B70>
            0.0618767738342 1.2836964 <ffpyplayer.pic.Image object at 0x02411B98>
            0.0610010623932 1.3448248 <ffpyplayer.pic.Image object at 0x02411BC0>
            0.0611264705658 1.4059532 <ffpyplayer.pic.Image object at 0x02411BE8>

        Or when the output format is yuv420p::

            ...
            >>> player = MediaPlayer(filename, callback=weakref.ref(callback),
            ... ff_opts={'out_fmt':'yuv420p'})
            >>> while 1:
            ...     frame, val = player.get_frame()
            ...     if val == 'eof':
            ...         break
            ...     elif frame is None:
            ...         time.sleep(0.01)
            ...         print 'not ready'
            ...     else:
            ...         img, t = frame
            ...         print val, t, img.get_pixel_format(), img.get_buffer_size()
            ...         time.sleep(val)
            ...
            0.0 0.0 yuv420p (309760, 77440, 77440, 0)
            0.0361273288727 0.0611284 yuv420p (309760, 77440, 77440, 0)
            0.0502526760101 0.1222568 yuv420p (309760, 77440, 77440, 0)
            0.12150645256 0.1833852 yuv420p (309760, 77440, 77440, 0)
            0.122756242752 0.2445136 yuv420p (309760, 77440, 77440, 0)
        '''
        cdef Image next_image = self.next_image
        cdef int res, f = force_refresh
        cdef int s = show
        cdef double pts, remaining_time

        if not s:
            next_image = None
        with nogil:
            res = self.ivs.video_refresh(next_image, &pts, &remaining_time, f)

        if res == 1:
            return (None, 'paused')
        elif res == 2:
            return (None, 'eof')
        elif res == 3:
            return (None, remaining_time)

        if s:
            self.next_image = Image.__new__(Image, no_create=True)
        return ((next_image, pts), remaining_time)

    def get_metadata(self):
        '''Returns metadata of the file being played.

        :returns:

            dict:
                Media file metadata. e.g. `frame_rate` is reported as a
                numerator and denominator. src and sink video sizes correspond to
                the frame size of the original video, and the frames returned by
                :meth:`get_frame`, respectively. `src_pix_fmt` is the pixel format
                of the original input stream. Duration is the file duration and
                defaults to None until updated.

        ::

            >>> print player.get_metadata()
            {'duration': 71.972, 'sink_vid_size': (0, 0), 'src_vid_size':
             (704, 480), 'frame_rate': (13978, 583),
             'title': 'The Melancholy of Haruhi Suzumiya: Special Ending',
             'src_pix_fmt': 'yuv420p'}

        .. warning::

            The dictionary returned will have default values until the file is
            open and read. Because a second thread is created and used to read
            the file, when the constructor returns the dict might still have
            the default values.

            After the first frame is read, the dictionary entries are correct
            with respect to the file metadata. Alternatively, you can wait
            until the desired parameter is updated from its default value.
            Note, the metadata dict will be updated even if the video is
            paused.

        .. note::

            Some paramteres can change as the streams are manipulated (e.g. the
            frame size and source format parameters).
        '''
        return self.ivs.metadata

    def select_video_filter(self, index=0):
        '''Selects the video filter to use from among the list of filters passed
        with the ff_opts `vf` options.
        '''
        if (self.settings.vfilters_list == NULL or
            index >= self.settings.nb_vfilters or index < 0):
            raise ValueError(index)
        self.ivs.vfilter_idx = index

    def set_volume(self, volume):
        '''Sets the volume of the audio.

        :Parameters:

            `volume`: float
                A value between 0.0 - 1.0.
        '''
        self.settings.audio_volume = av_clip(volume * SDL_MIX_MAXVOLUME, 0, SDL_MIX_MAXVOLUME)

    def get_volume(self):
        '''Returns the volume of the audio.

        :returns:

            `float`: A value between 0.0 - 1.0.
        '''
        return self.settings.audio_volume / <double>SDL_MIX_MAXVOLUME

    def set_mute(self, state):
        '''Mutes or un-mutes the audio.

        :Parameters:

            `state`: bool
                Whether to mute or unmute the audio.
        '''
        self.settings.muted = state

    def get_mute(self):
        '''Returns whether the player is muted.
        '''
        return bool(self.settings.muted)

    def toggle_pause(self):
        '''Toggles the player's pause state.
        '''
        with nogil:
            self.ivs.toggle_pause()

    def set_pause(self, state):
        '''Pauses or un-pauses the file.

        :Parameters:

            `state`: bool
                Whether to pause or un-pause the player.
        '''
        if self.ivs.paused and state or not self.ivs.paused and not state:
            return
        with nogil:
            self.ivs.toggle_pause()

    def get_pause(self):
        '''Returns whether the player is paused.
        '''
        return bool(self.ivs.paused)

    def get_pts(VideoState self):
        '''Returns the elapsed play time.

        :returns:

            `float`:
                The amount of the time that the file has been playing.
                The time is from the clock used for the player (default is audio,
                see ``sync`` options). If the clock is based on video, it should correspond
                with the pts from get_frame.
        '''
        cdef double pos
        cdef int sync_type = self.ivs.get_master_sync_type()
        if (sync_type == AV_SYNC_VIDEO_MASTER and
            self.ivs.video_stream != -1):
            pos = self.ivs.vidclk.get_clock()
        elif (sync_type == AV_SYNC_AUDIO_MASTER and
            self.ivs.audio_stream != -1):
            pos = self.ivs.audclk.get_clock()
        else:
            pos = self.ivs.extclk.get_clock()
        if isnan(pos):
            pos = <double>self.ivs.seek_pos / <double>AV_TIME_BASE
        if (self.ivs.ic.start_time != AV_NOPTS_VALUE and
            pos < self.ivs.ic.start_time / <double>AV_TIME_BASE):
            pos = self.ivs.ic.start_time / <double>AV_TIME_BASE
        return pos

    def set_size(self, int width=-1, int height=-1):
        '''Dynamically sets the size of the frames returned by :meth:`get_frame`.

        :Parameters:

            `width, height`: int
                The width and height of the output frames.
                A value of 0 will set that parameter to the source width/height.
                A value of -1 for one of the parameters, will result in a value of that
                parameter that maintains the original aspect ratio.

        For example ::

            >>> print player.get_frame()[0][0].get_size()
            (704, 480)

            >>> player.set_size(200, 200)
            >>> print player.get_frame()[0][0].get_size()
            (704, 480)
            >>> print player.get_frame()[0][0].get_size()
            (704, 480)
            >>> print player.get_frame()[0][0].get_size()
            (704, 480)
            >>> print player.get_frame()[0][0].get_size()
            (200, 200)

            >>> player.set_size(200, 0)
            >>> print player.get_frame()[0][0].get_size()
            (200, 200)
            >>> print player.get_frame()[0][0].get_size()
            (200, 200)
            >>> print player.get_frame()[0][0].get_size()
            (200, 480)

            >>> player.set_size(200, -1)
            >>> print player.get_frame()[0][0].get_size()
            (200, 480)
            >>> print player.get_frame()[0][0].get_size()
            (200, 480)
            >>> print player.get_frame()[0][0].get_size()
            (200, 136)

        Note, that it takes a few calls to flush the old frames.

        .. note::

            if CONFIG_AVFILTER was False when compiling, this function will raise
            an error.
        '''
        if not CONFIG_AVFILTER and (width or height):
            raise Exception('You can only set the screen size when avfilter is enabled.')
        self.settings.screen_width = width
        self.settings.screen_height = height

    def get_output_pix_fmt(self):
        '''Returns the pixel fmt in which output images are returned when calling
        :attr:`get_frame`.

        You can set the output format by specifying ``out_fmt`` in ``ff_opts``
        when creating this instance. Also, if avfilter is enabled, you can
        change it dynamically with :meth:`set_output_pix_fmt`.

        ::

            >>> print(player.get_output_pix_fmt())
            rgb24
        '''
        return self.ivs.get_out_pix_fmt()

    def set_output_pix_fmt(self, pix_fmt):
        '''Sets the pixel fmt in which output images are returned when calling
        :meth:`get_frame`.

        For example::

            >>> player.set_output_pix_fmt('yuv420p')

        sets the output format to use. This will only take effect on images that
        have not been queued yet so it may take a few calls to :meth:`get_frame`
        to reflect the new pixel format.

        .. note::

            if CONFIG_AVFILTER was False when compiling, this function will raise
            an exception.
        '''
        cdef AVPixelFormat fmt
        cdef bytes pix_fmt_b
        if not CONFIG_AVFILTER:
            raise Exception('You can only change the fmt when avfilter is enabled.')

        pix_fmt_b = pix_fmt.encode('utf8')
        fmt = av_get_pix_fmt(pix_fmt_b)
        if fmt == AV_PIX_FMT_NONE:
            raise Exception('Unrecognized output pixel format {}.'.format(pix_fmt))
        self.ivs.set_out_pix_fmt(fmt)

    # Currently, if a stream is re-opened when the stream was not open before
    # it'l cause some seeking. We can probably remove it by setting a seek flag
    # only for this stream and not for all, provided is not the master clock stream.
    def request_channel(self, stream_type, action='cycle', int requested_stream=-1):
        '''Opens or closes a stream dynamically.

        This function may result in seeking when opening a new stream.

        :Parameters:

            `stream_type`: str
                The stream group on which to operate. Can be one of ``'audio'``,
                ``'video'``, or ``'subtitle'``.
            `action`: str
                The action to perform. Can be one of ``'open'``, ``'close'``, or
                ``'cycle'``. A value of 'cycle' will close the current stream and
                open the next stream in this group.
            `requested_stream`: int
                The stream to open next when ``action`` is ``'cycle'`` or ``'open'``.
                If ``-1``, the next stream will be opened. Otherwise, this stream will
                be attempted to be opened.
        '''
        cdef int stream, old_index
        if stream_type == 'audio':
            stream = AVMEDIA_TYPE_AUDIO
            old_index = self.ivs.audio_stream
        elif stream_type == 'video':
            stream = AVMEDIA_TYPE_VIDEO
            old_index = self.ivs.video_stream
        elif stream_type == 'subtitle':
            stream = AVMEDIA_TYPE_SUBTITLE
            old_index = self.ivs.subtitle_stream
        else:
            raise Exception('Invalid stream type')
        if action == 'open' or action == 'cycle':
            with nogil:
                self.ivs.stream_cycle_channel(stream, requested_stream)
        elif action == 'close':
            self.ivs.stream_component_close(old_index)

    def seek(self, pts, relative=True, seek_by_bytes='auto', accurate=True):
        '''Seeks in the current streams.

        Seeks to the desired timepoint as close as possible while not exceeding
        that time.

        :Parameters:

            `pts`: float
                The timestamp to seek to (in seconds).
            `relative`: bool
                Whether the pts parameter is interpreted as the
                time offset from the current stream position (can be negative if True).
            `seek_by_bytes`: bool or ``'auto'``
                Whether we seek based on the position in bytes or in time. In some
                instances seeking by bytes may be more accurate (don't ask me which).
                If ``'auto'``, the default, it is automatically decided based on
                the media.
            `accurate`: bool
                Whether to do finer seeking if we didn't seek directly to the requested
                frame. This is likely to be slower because after the coarser seek,
                we have to walk through the frames until the requested frame is
                reached. If paused or we reached eof this is ignored. Defaults to True.

        For example::

            >>> print player.get_frame()[0][1]
            1016.392

            >>> player.seek(200., accurate=False)
            >>> player.get_frame()
            >>> print player.get_frame()[0][1]
            1249.876

            >>> player.seek(200, relative=False, accurate=False)
            >>> player.get_frame()
            >>> print player.get_frame()[0][1]
            198.49

        Note that it may take a few calls to get new frames after seeking.
        '''
        cdef int c_relative = relative
        cdef int c_accurate = accurate
        cdef int c_seek_by_bytes
        cdef double c_pts = pts
        if seek_by_bytes == 'auto':
            c_seek_by_bytes = self.settings.seek_by_bytes > 0
        else:
            c_seek_by_bytes = seek_by_bytes

        with nogil:
            self._seek(c_pts, c_relative, c_seek_by_bytes, c_accurate)

    def seek_to_chapter(self, increment, accurate=True):
        '''Seeks forwards or backwards (if negative) by ``increment`` chapters.

        :Parameters:

            `increment`: int
                The number of chapters to seek forwards or backwards to.
            `accurate`: bool
                Whether to do finer seeking if we didn't seek directly to the requested
                frame. This is likely to be slower because after the coarser seek,
                we have to walk through the frames until the requested frame is
                reached. Defaults to True.
        '''
        cdef int c_increment = increment
        cdef int c_accurate = accurate
        with nogil:
            self.ivs.seek_chapter(c_increment, c_accurate)

    cdef void _seek(self, double pts, int relative, int seek_by_bytes, int accurate) nogil:
        '''Returns the actual pos where we wanted to seek to.
        '''
        cdef double incr, pos
        cdef int64_t t_pos = 0, t_rel = 0

        if relative:
            incr = pts
            if seek_by_bytes:
                pos = -1
                if self.ivs.video_stream >= 0:
                    pos = self.ivs.pictq.frame_queue_last_pos()
                if pos < 0 and self.ivs.audio_stream >= 0:
                    pos = self.ivs.sampq.frame_queue_last_pos()
                if pos < 0:
                    pos = avio_tell(self.ivs.ic.pb)
                if self.ivs.ic.bit_rate:
                    incr *= self.ivs.ic.bit_rate / 8.0
                else:
                    incr *= 180000.0
                pos += incr
                t_pos = <int64_t>pos
                t_rel = <int64_t>incr
            else:
                pos = self.ivs.get_master_clock()
                if isnan(pos):
                    # seek_pos might never have been set
                    pos = <double>self.ivs.seek_pos / <double>AV_TIME_BASE
                pos += incr
                if self.ivs.ic.start_time != AV_NOPTS_VALUE and pos < self.ivs.ic.start_time / <double>AV_TIME_BASE:
                    pos = self.ivs.ic.start_time / <double>AV_TIME_BASE
                t_pos = <int64_t>(pos * AV_TIME_BASE)
                t_rel = <int64_t>(incr * AV_TIME_BASE)
        else:
            pos = pts
            if seek_by_bytes:
                if self.ivs.ic.bit_rate:
                    pos *= self.ivs.ic.bit_rate / 8.0
                else:
                    pos *= 180000.0
                t_pos = <int64_t>pos
            else:
                t_pos = <int64_t>(pos * AV_TIME_BASE)
                if self.ivs.ic.start_time != AV_NOPTS_VALUE and t_pos < self.ivs.ic.start_time:
                    t_pos = self.ivs.ic.start_time
        self.ivs.stream_seek(t_pos, t_rel, seek_by_bytes, accurate)

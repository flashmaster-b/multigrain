/**
 * A grain synthesizer with two modes: one that overlays multiple channels with 
 * slightly different generation rates, that creates modulations between
 * layers for interesting soundscapes, and one that is a classic grain synthesizer
 * 
 * seven different buffers can be chosen, that all have to be already loaded 
 * on startup
 * 
 * @author		Jürgen Buchinger <buchido@gmail.com>
 * @version 	3.11
 * @date		10 Jan 2024
 * 
 */
s = Server.default;

s.options.numAnalogInChannels = 8;
s.options.numAnalogOutChannels = 2;
s.options.numDigitalChannels = 16;

s.options.blockSize = 2048;
s.options.numInputBusChannels = 2;
s.options.numOutputBusChannels = 2;

s.options.postln;

s.waitForBoot({
	~b0 = Buffer.read(s, "hemberg_1.wav");
	~b1 = Buffer.read(s, "bell_mono_.wav");
	~b2 = Buffer.read(s, "glazing.wav");
	~b3 = Buffer.read(s, "01-tom-rakatu-empty.aif");
	~b4 = Buffer.read(s, "03-dogo-talk_el.wav");
	~b5 = Buffer.read(s, "galeano.wav");
	~b6 = Buffer.read(s, "arabic.wav");
	
	/**
	 * here we can change between a standing grain pointer 
	 * and a moving one
	 */
	
	~selpointer = {
		var d11 = DigitalIn.kr(11);
		SendReply.kr(Changed.kr(DigitalIn.kr(11)), '/selpointer', d11);
	}.play;
	
	~curpointer = 0;

	OSCdef(\selpointer, {
			arg msg;
			~curpointer = ~curpointer + msg[3];
			~curpointer = ~curpointer % 2;
			~mg.set(\pointer_mode, ~curpointer);
			~sl.set(\point, ~curpointer);
		},
		'/selpointer'
	);

	/**
	 * Here we are setting the synth modus by pressing
	 * button at d0...
	 */
	
	~selsynth = {
		var d0 = DigitalIn.kr(0);
		SendReply.kr(Changed.kr(DigitalIn.kr(0)), '/selsynth', d0);
	}.play;
	
	~cursynth = 0;

	OSCdef(\selsynth, {
			arg msg;
			~cursynth = ~cursynth + msg[3];
			~cursynth = ~cursynth % 2;
			~sl.set(\land, ~cursynth);
			~sl.set(\grain, if(~cursynth == 1, 0, 1));
		},
		'/selsynth'
	);
	
	/**
	 * ... and setting the corresponding LED
	 */
	
	SynthDef(\synthled, {
		arg land=0, grain=1, point=0;
		DigitalIO.kr(1, grain, 1);
		DigitalIO.kr(2, land, 1);
		DigitalIO.kr(5, point, 1);
	}).add;
	
	/**
	 * this is the actual synth that plays sound, there
	 * are two modi:
	 *  1) A granulator
	 *  2) A multi-channel granulator
	 *  
	 * The arguments for them are
	 *	   0          1          2         3         4            5          6
	 *  1) position   spray      size      spray.    density      pitch      vol
	 *  2) position   spray      size      spray     freq         pitch      vol
	 */

	SynthDef(\multigrain, {
		/**
		 * vol is volume,
		 * select is the selected synth,
		 * pointermode is if we loop through the buffer 
		 * or stand at one point for grain generation
		 * pitch2 and pos2 are deviations from pitch and pos by midi in <- FIX: does that make sense?
		 */
		arg select=0, pointer_mode=0, gate=0, pitch2, pos2=0;
		
		/**
		 * the output volume
		 */
		var vol = AnalogIn.kr(6);
		
		/**
		 * the buffer to generate grains from.
		 * We have five sample in five different buffers,
		 * samples are loaded at the beginning and cannot be
		 * changed on runtime, however, you can change 
		 * continuously between the five samples.
		 * We use an analog potentiometer to choose,
		 * the limits are empirical values:
		 * Buffer no           1        2        3        4        5 
		 * Poti value   0.1875   0.3125   0.4375   0.5625   0.6875   0.8125
		 */
		 var bufnum = (AnalogIn.kr(7)*8-(1.0/12.0)).round;
		 var buf = Select.kr(bufnum, [~b0, ~b0, ~b1, ~b2, ~b3, ~b4, ~b5, ~b6, ~b5]);

		/**
		 * the starting position in the buffer for new grains, or,
		 * if pointermode = 1, the speed with which to loop through
		 * the buffer
		 */ 
		var pos = Select.kr(pos2>0, [
			Select.kr(pointer_mode, [
				AnalogIn.kr(0), 
				Phasor.ar(0, BufRateScale.kr(buf)/BufFrames.kr(buf) * AnalogIn.kr(0).exprange(0.1,10), 0, 1)
			]), 
			Select.kr(pointer_mode, [
				pos2, 
				Phasor.ar(0, BufRateScale.kr(buf)/BufFrames.kr(buf) * AnalogIn.kr(0).exprange(0.1,10), pos2, 1, 0)
			])
		]);
		
		/**
		 * psition two is deviation from position acc to midi
		 */
		
		
		/**
		 * the grain size in seconds (5 ms - 200 ms)
		 */
		var size = AnalogIn.kr(2).exprange(0.005, 0.2); 

		/** 
		 * The grain production rate in grains per seconds
		 * this in combination with grain size controls the amount
		 * of grains played simultaneously, i.e. the density of 
		 * the grain cloud.
		 * We map the potentiometer so that the slowest is 1 Hz
		 * and the highest is so that the number of grains simultaneaously
		 * played is not more then 64 (which is also the limit of the
		 * GrainBuf UGen and our bela mini). Maybe later we add a little
		 * becuase it generates a nice modulating effect when GrainBuf
		 * reaches its grain limit;
		 */
		var density = AnalogIn.kr(4).exprange(1, 128/size);
		
		/**
		 * The amount of input jitter, i.e. the amount that the 
		 * starting position is randomly moved forward or backward 
		 * for each grain.
		 * It is set as a multiple of the whole duration of the buffer
		 * in each direction, i.e. 0.5 is a completely random 
		 * starting position, 0.05 a jitter of 10 % of the whole
		 * duration of the buffer.
		 */
		var spray = AnalogIn.kr(1).range(0.001, 0.5);

		/**
		 * the speed at which to play the grains
		 */
		var pitch = AnalogIn.kr(5).exprange(0.5, 2);
		
		/**
		 * The jitter for the grain size, in seconds (1 ms - 100 ms)
		 * Will be added to grain size.
		 */
		var size_spray = AnalogIn.kr(3).range(0.001, 0.1);
		var land_size_spray = AnalogIn.kr(3).range(0.0001, 0.1);
		
		/**
		 * The minimum and maximum grain size. Grains will be
		 * generated randomly (but slewed) between those limits.
		 * We use very small minimum values here, because even 
		 * click sounds can generate nice modulation when
		 * overlayed over each other.
		 */
		var land_size = AnalogIn.kr(2).exprange(0.0002, 0.1);
		
		/**
		 * the frequency with which to change position and length of grains
		 */
		var freq = AnalogIn.kr(4).exprange(0.01,5);
		
		/** 
		 * the envelope for midi mode
		 */
		var env = EnvGen.kr(Env.adsr(0.1, 0.3, 0.7, 0.3), gate, doneAction: 2);
		
		var sig;
	
		DigitalIO.kr(6, if(AnalogIn.kr(7) < 0.3125, 1, 0), 1);
		DigitalIO.kr(7, if(AnalogIn.kr(7) >= 0.3125, if(AnalogIn.kr(7) < 0.4375, 1, 0), 0), 1);
		DigitalIO.kr(8, if(AnalogIn.kr(7) >= 0.4375, if(AnalogIn.kr(7) < 0.5625, 1, 0), 0), 1);
		DigitalIO.kr(9, if(AnalogIn.kr(7) >= 0.5625, if(AnalogIn.kr(7) < 0.6875, 1, 0), 0), 1);
		DigitalIO.kr(10, if(AnalogIn.kr(7) >= 0.6875, 1, 0), 1);


		sig = if(select,
			GrainBuf.ar(
				1,
				Impulse.ar(ExpRand(50,50.5)!10),
				LFNoise1.kr(freq!10).exprange(land_size,land_size+land_size_spray),
				buf,
				pitch,
				pos + LFNoise1.kr(freq!10).bipolar(spray),
				2,
				0,
				-1,
				10,
				vol
			),
			GrainBuf.ar(
				2,
				Impulse.ar(density),
				size + LFNoise0.ar(density).unipolar(size_spray),
				buf,
				(pitch2 - 60 + AnalogIn.kr(5).range(-12,12)).midiratio,
				pos + LFNoise0.ar(density, spray),
				2,
				0,
				-1,
				128,
				vol
			)
		);
			
		sig = Splay.ar(sig);
		sig = Normalizer.ar(sig, vol);
		sig = sig * env;
		Out.ar(0, sig);
	}).send(s);
	
	
	MIDIClient.init;
	MIDIIn.connectAll;
	
	// m = MIDIOut(0, MIDIClient.destinations[0].uid);
	
	~notes = Array.newClear(128);    // array has one slot per possible MIDI note
	
	~on = MIDIFunc.noteOn({ |veloc, num, chan, src|
		~notes[num] = Synth(\multigrain, [\pitch2, 60, \pos2, (num-48)/(72-48), \gate, 1, \pointer_mode, ~curpointer, \select, ~cursynth]);
	});

	~off = MIDIFunc.noteOff({ |veloc, num, chan, src|
		~notes[num].set(\gate, 0);
	});

	// drone mode
	~drone = {
		SendReply.kr(Changed.kr(DigitalIn.kr(12)), '/drone', DigitalIn.kr(12));
	}.play;
	
	OSCdef(\drone, {
			arg msg;
			if(msg[3] > 0, { ~mg = Synth(\multigrain, [\pitch2, 60, \gate, 1, \pointer_mode, ~curpointer, \select, ~cursynth]) }, { ~mg.set(\gate, 0) });
		},
		'/drone'
	);
	
	s.sync;
	
	// the synth mode selection LED
	~sl = Synth.new(\synthled);
	
});
ServerQuit.add({ 0.exit }); // quit if the button is pressed

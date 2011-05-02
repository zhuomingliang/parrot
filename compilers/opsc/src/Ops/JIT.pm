#! parrot-nqp

=begin Description

LLVM JITter?

=end Description

class Ops::JIT;

# Debug outputs.
has $!debug;

# Ops::OpsFile
has $!ops_file;
has %!ops;

# OpLib
has $!oplib;

# Packfile used.
has $!packfile;
has $!constants;
has $!bytecode;
has $!opmap;

# LLVM stuff
has $!module;
has $!builder;
has $!jitted_sub;

# Predefined functions from $!module
has %!functions;

has $!interp_struct_type;
has $!opcode_ptr_type;

# type->name mapping.
has %!types;

=item new
Create new JITter for given PBC and OpsFile.

method new(Str $pbc, Ops::File $ops_file, OpLib $oplib, :$debug?) {
    $!debug    := ?$debug;
    $!ops_file := $ops_file;
    $!oplib    := $oplib;

    # Generate lookup hash by opname.
    for $ops_file.ops -> $op {
        Ops::Util::strip_source($op);
        %!ops{$op.full_name} := $op;
    };

    self._load_pbc($pbc);

    self._init_llvm();

    self;
}

=item load_pbc
Load PBC file.

method _load_pbc(Str $file) {
    # Load PBC into memory
    my $handle   := open($file, :r, :bin);
    my $contents := $handle.readall;
    $handle.close();

    $!packfile := pir::new('Packfile');
    $!packfile.unpack($contents);

    # Find Bytecode and Constants segments.
    my $dir := $!packfile.get_directory() // die("Couldn't find directory in Packfile");

    # Types:
    # 2 Constants.
    # 3 Bytecode.
    # 4 DEBUG
    for $dir -> $it {
        #say("Segment { $it.key } => { $it.value.type }");
        my $segment := $it.value;
        if $segment.type == 2 {
            $!constants := $segment;
        }
        elsif $segment.type == 3 {
            $!bytecode := $segment;
        }
    }

    # Sanity check
    $!bytecode // die("Couldn't find Bytecode");
    $!constants // die("Couldn't find Constants");

    $!opmap := $!bytecode.opmap() // die("Couldn't load OpMap");
}

=item _init_llvm
Initialize LLVM

method _init_llvm() {
    # t/jit/jitted_ops.bc generated by:
    # ./ops2c -d t/jit/jitted.ops
    # llvm-gcc-4.2 -emit-llvm -O0 -Iinclude -I/usr/include/i486-linux-gnu -o t/jit/jitted_ops.bc -c t/jit/jitted_ops.c
    $!module := LLVM::Module.create('JIT');
    $!module.read("t/jit/jitted_ops.bc")
             // die("Couldn't read t/jit/jitted_ops.bc");

    # Copy actual types from loaded module.
    LLVM::Type::initialize_from_module($!module);

    $!builder := LLVM::Builder.create();

    # Shortcuts for types
    $!interp_struct_type := $!module.get_type("struct.parrot_interp_t")
                            // die("Couldn't find parrot_interp_t definition");

    $!opcode_ptr_type := LLVM::Type::pointer(LLVM::Type::UINTVAL());

    # Create lookup hash for functions, declared in $!module;
    my $f := $!module.first_function;
    while $f {
        my $name := $f.name;
        %!functions{ $name } := $f;

        # XXX PCC functions are aliased. And we don't have "cpp" (yet?)
        if $name ~~ / '_func' $/ {
            $name := pir::substr($name, 0, pir::length($name) - 5);
            %!functions{ $name } := $f;
        }
        $f := $f.next;
    }

    # TODO: Generate lookup map for Type-to-Name.
    %!types := $!module.get_types;
}

=begin Processing

We process bytecode from $start position. $end isn't required because last op
in any sub will be :flow op. E.g. C<returncc> or C<end>.

1. We create new LLVM::Function for jitted bytecode. Including prologue and
epilogue.

2. Iterate over ops and create LLVM::BasicBlock for each. This step is
required for handling "local branches" - C<branch>, C<lt>, etc.

3. Iterate over ops again and jit every op. We can stop early for various
reasons - non-local jump, unhandled construct, etc. 

4. For the rest of non-processed ops we just remove BasicBlocks.

5. Run LLVM optimizer.

6. JIT new function.

7. ... add dynop lib to interp? Store new function in it and alter bytecode?
Any other ways?

8. Invoke function.

=end Processing

=item jit($start)
JIT bytecode starting from C<$start> position.

method jit($start, :$optimize = 1) {

    # jit_context hold state for currently jitting ops.
    my %jit_context := self._create_jit_context($start);

    # Generate JITted function for Sub. I use "functional" approach
    # when functions doesn't have side-effects. This is main reason
    # for having such signature.
    %jit_context := self._create_jitted_function(%jit_context, $start);
    $!debug && $!jitted_sub.dump;

    %jit_context := self._create_basic_blocks(%jit_context);
    $!debug && $!jitted_sub.dump;

    %jit_context := self._jit_ops(%jit_context);
    $!debug && $!jitted_sub.dump;

    # Verify module berofre optimizatio.
    $!module.verify();
    %jit_context := self._optimize(%jit_context) if $optimize;

    $!debug && $!jitted_sub.dump;

    %jit_context;
}

method module() {
    $!module;
}

method _create_jit_context($start) {
    hash(
        bytecode    => $!bytecode,
        constants   => $!constants,
        start       => $start,
        cur_opcode  => $start,

        lhs         => 0,

        basic_blocks => hash(), # offset->basic_block
        variables    => hash(), # name -> LLVM::Value
    );
}

method _create_jitted_function (%jit_context, $start) {

    # Generate JITted function for Sub.
    $!jitted_sub := $!module.add_function(
        "jitted$start",
        $!opcode_ptr_type,
        $!opcode_ptr_type,
        LLVM::Type::pointer($!interp_struct_type),
    );
    %jit_context<jitted_sub> := $!jitted_sub;

    #$module.dump();

    # Handle arguments
    my $entry := $!jitted_sub.append_basic_block("entry");
    %jit_context<entry> := $entry;

    # Create explicit return
    my $leave := $!jitted_sub.append_basic_block("leave");
    %jit_context<leave> := $leave;

    # Handle args.
    $!builder.set_position($entry);

    $!debug && say("# cur_opcode");
    my $cur_opcode := $!jitted_sub.param(0);
    $cur_opcode.name("cur_opcode");
    my $cur_opcode_addr := $!builder.alloca($cur_opcode.typeof()).name("cur_opcode_addr");
    %jit_context<variables><cur_opcode> := $cur_opcode_addr;
    $!builder.store($cur_opcode, $cur_opcode_addr);

    # '#define CUR_OPCODE cur_opcode'
    %jit_context<variables><CUR_OPCODE> := $cur_opcode_addr;

    $!debug && say("# interp");
    my $interp := $!jitted_sub.param(1);
    $interp.name("interp");
    my $interp_addr := $!builder.alloca($interp.typeof()).name("interp_addr");
    $!builder.store($interp, $interp_addr);
    %jit_context<variables><interp> := $interp_addr;

    # Few helper values
    $!debug && say("# retval");
    my $retval := $!builder.alloca($!opcode_ptr_type).name("retval");
    %jit_context<variables><retval> := $retval;

    $!debug && say("# .CUR_CTX");
    # Load current context from interp
    my $cur_ctx := $!builder.struct_gep($interp, 0, '.CUR_CTX');
    %jit_context<variables><.CUR_CTX> := $cur_ctx;

    # Constants
    $!debug && say("# str_constants");
    %jit_context<str_constants> := $!builder.call(
        %!functions<Parrot_pcc_get_str_constants_func>,
        $!builder.load(%jit_context<variables><interp>),
        $!builder.load(%jit_context<variables><.CUR_CTX>),
        :name('.str_constants')
    );

    $!debug && say("# pmc_constants");
    %jit_context<pmc_constants> := $!builder.call(
        %!functions<Parrot_pcc_get_pmc_constants_func>,
        $!builder.load(%jit_context<variables><interp>),
        $!builder.load(%jit_context<variables><.CUR_CTX>),
        :name('.pmc_constants')
    );

    %jit_context<variables><PMCNULL> := $!module.get_global(:name<PMCNULL>);

    # NULL isn't variable. But treat it as variable simplify life.
    %jit_context<variables><NULL> := LLVM::Constant::null(LLVM::Type::pointer(LLVM::Type::void()));

    # It's actually macro, but Preprocessor supports only "function" macros.
    %jit_context<variables><NEED_CONTINUATION> := LLVM::Constant::int_to_ptr(
        LLVM::Constant::integer(1),
        LLVM::Type::PMC_PTR(),
    );

    # Create default return.
    $!debug && say("# default leave");
    $!builder.set_position($leave);
    $!builder.ret(
        $!builder.load($retval)
    );

    %jit_context;
}

method _create_basic_blocks(%jit_context) {

    my $bc          := %jit_context<bytecode>;
    my $entry       := %jit_context<entry>;
    my $leave       := %jit_context<leave>;
    my $i           := %jit_context<start>;
    my $total       := +$bc - %jit_context<start>;
    my $keep_going  := 1;

    # Enumerate ops and create BasicBlock for each.
    while $keep_going && ($i < $total) {
        # Mapped op
        my $id     := $bc[$i];

        # Real opname
        my $opname := $!opmap[$id];

        # Get op
        my $op     := $!oplib{$opname};

        $!debug && say("# $opname");
        my $bb := $leave.insert_before("L$i");
        %jit_context<basic_blocks>{$i} := hash(
            label => "L$i",
            bb    => $bb,
        );

        # Next op
        $i := $i + self._opsize(%jit_context, $op);

        $keep_going   := self._keep_going($opname);

        #say("# keep_going $keep_going { $parsed_op<flags>.keys.join(',') }");
    }

    # Branch from "entry" BB to next one.
    $!builder.set_position($entry);
    $!builder.br($entry.next);

    %jit_context;
}

=item _jit
JIT opcodes.

method _jit_ops(%jit_context) {
    # "JIT" Sub
    my $bc          := %jit_context<bytecode>;
    my $i           := %jit_context<start>;
    my $total       := +$bc - %jit_context<start>;
    my $keep_going  := 1;

    # Enumerate ops and create BasicBlock for each.
    while $keep_going && ($i < $total) {
        my $id     := $bc[$i];          # Mapped op
        my $opname := $!opmap[$id];      # Real opname
        my $op     := $!oplib{$opname};  # Get op

        $!debug && say("# jit $opname ");

        # Position Builder to previousely created BB.
        $!builder.set_position(%jit_context<basic_blocks>{$i}<bb>);

        my $parsed_op := %!ops{ $opname }
                         // die("Op $opname isn't jitted");

        # Meh... Multidispatch passed it to process(PAST::Block) instead of
        # Ops::Op. process_op is workaround for it.
        my $jitted_op := self.process_op($parsed_op, %jit_context);

        # Next op
        $i := $i + self._opsize(%jit_context, $op);
        %jit_context<cur_opcode> := $i;

        $keep_going   := self._keep_going($opname);
    }

    %jit_context;
}

=item _count_args
Calculate number of op's args. In most cases it's predefined for op. For 4
exceptions C<set_args>, C<get_results>, C<get_params>, C<set_returns> we have
to calculate it in run-time..

method _opsize(%c, $op) {
    if _op_is_special(~$op) {
        $!debug && say("Checking special op size");
        my $id := self._opcode_at(1, %c);
        $!debug && say("PCC constant $id");
        my $fia := %c<constants>[$id];

        $!debug && say("_opize { 2 + pir::elements($fia) }");
        2 + pir::elements($fia);
    }
    else {
        1 + pir::elements($op);
    }
}

=item _op_is_special
Check that op has vaiable length

sub _op_is_special($name) {
    $name eq 'set_args_pc'
    || $name eq 'get_results_pc'
    || $name eq 'get_params_pc'
    || $name eq 'set_returns_pc';
}

=item _keep_going
Should we continue processing ops? If this is non-special :flow op - stop now.

method _keep_going($opname) {
    # If this is non-special :flow op - stop.
    my $parsed_op := %!ops{ $opname };
    $parsed_op && (
        _op_is_special($opname)
        || $parsed_op<flags><base_loop> # "branch" and "jump"
        || !$parsed_op<flags><flow>
    );
}



=item process(Ops::Op, %c) -> Bool.
Process single Op. Return false if we should stop JITting. Dies if can't handle op.
We stop on :flow ops because PCC will interrupt "C" flow and our PCC is way too
complext to implement it in JITter.

method process_op(Ops::Op $op, %c) {
    $!debug && say("# Handling { $op.full_name }");
    %c<op> := $op;
    self.process($_, %c) for @($op);
    %c.delete('op');

    $!debug && $!jitted_sub.dump();
}

# Recursively process body chunks returning string.
our multi method process(PAST::Val $val, %c) {
    my $type := $val.returns;
    if $type eq 'string' {
        $!builder.global_string_ptr($val.value, :name<.str>);
    }
    elsif $type eq 'int' {
        LLVM::Constant::integer($val.value);
    }
    else {
    }
}

our multi method process(PAST::Var $var, %c) {
    my $res;
    if $var.isdecl {
        # There is some challanges here.
        # .vivibase can be:
        # 1. Native type. E.g. "int".
        # 2. Typedefed native type. E.g. "opcode_t".
        # 3. Struct (pointer)
        my $vivibase := subst($var.vivibase, / \s* $/, '');
        $!debug && say("# Variable '{ $var.name }' type '$vivibase'");

        # Assume that all types have constructor in LLVM::Type.
        my $ctor := pir::get_hll_global__pps(<LLVM Type>, $vivibase);
        my $type := $ctor();
        if $var<pointer> {
            $type := LLVM::Type::pointer($type);
        }

        my $res := $!builder.alloca($type, :name($var.name));
        %c<variables>{ $var.name } := $res;

        if $var.viviself {
            $!debug && say("# Initialize it");
            $!debug && _dumper($var.viviself);
            $!builder.store(self.process($var.viviself, %c), $res);
        }
    }
    else {
        if $var.scope eq 'register' {
            my $num  := $var.name;
            my $type := %c<op>.arg_type($num - 1);
            $!debug && say("# Handling '$type' register");
            my $sub  := pir::find_sub_not_null__ps('access_arg:type<' ~ $type ~ '>');
            $res := $sub(self, $num, %c);
        }
        elsif $var.scope eq 'keyed_arrow' {
            my $old := +%c<lhs>;
            %c<lhs> := 0;
            my $lhs := self.process($var[0], %c);
            %c<lhs> := $old;

            if $!debug {
                say("# keyed_arrow");
                say($lhs.dump());
                _dumper($var[1]);
            }

            # Figure out underlying type.
            $!debug && say("Kind " ~ $lhs.typeof.kind);
            die("Not a pointer { $lhs.dump }") unless $lhs.typeof.kind == LLVM::TYPE_KIND.POINTER;

            my $element_type := $lhs.typeof.element_type;
            $!debug && say("ElementType " ~ $element_type.kind);
            die("Not a struct") unless $element_type.kind == LLVM::TYPE_KIND.STRUCT;

            my $struct_type;
            for %!types.kv -> $k, $v {
                if pir::get_addr__ip($v) == pir::get_addr__ip($element_type) {
                    $struct_type := $k;
                }
            }
            die("Couldn't find struct definition") unless defined($struct_type);
            $!debug && say("Struct $struct_type");

            my $struct := %Ops::Compiler::STRUCT{ $struct_type };
            die("Unknown struct $struct_type") unless defined($struct);

            my $field := ~$var[1];
            die("Unknow field $field in $struct_type") unless $struct.exists($field);

            $!debug && say("Mapped $struct_type->$field to { $struct{ $field } }");
            my $res := $!builder.struct_gep($lhs, $struct{ $field });
            $res.dump();

        }
        else {
            $res := %c<variables>{ $var.name } // die("Unknown variable { $var.name }");
            $res := $!builder.load($res) unless %c<lhs>;
            $res;
        }
    }

    return undef unless $res;
    $res;
}

our method access_arg:type<i> ($num, %c) {
    my $res := self.get_int_reg($num, %c);
    $res := $!builder.load($res) unless %c<lhs>;
    $res;
}

our method access_arg:type<n> ($num, %c) {
    my $res := self.get_num_reg($num, %c);
    $res := $!builder.load($res) unless %c<lhs>;
    $res;
}

our method access_arg:type<p> ($num, %c) {
    my $res := self.get_pmc_reg($num, %c);
    $res := $!builder.load($res) unless %c<lhs>;
    $res;
}

our method access_arg:type<s> ($num, %c) {
    my $res := self.get_str_reg($num, %c);
    $res := $!builder.load($res) unless %c<lhs>;
    $res;
}

our method access_arg:type<k> ($num, %c) {
    my $res := self.get_pmc_reg($num, %c);
    $res := $!builder.load($res) unless %c<lhs>;
    $res;
}

our method access_arg:type<ki> ($num, %c) {
    my $res := self.get_int_reg($num, %c);
    $res := $!builder.load($res) unless %c<lhs>;
    $res;
}

our method access_arg:type<ic> ($num, %c) {
    $!debug && say("# $num <ic> { self._opcode_at($num, %c) }");
    LLVM::Constant::integer(self._opcode_at($num, %c));
}

our method access_arg:type<nc> ($num, %c) {
    die("Wrong LHS mode") if %c<lhs>;

    my $c   := %c<constants>;
    my $i   := self._opcode_at($num, %c);
    my $res := pir::set__NQi($c, $i);

    $!debug && say("# $num<nc> '$res'");
    #$!builder.global_string_ptr($res, :name<.SCONST>);

    LLVM::Constant::real($res);
}

our method access_arg:type<pc> ($num, %c) {
    die("Wrong LHS mode") if %c<lhs>;

    $!debug && _dumper(%c<pmc_constants>);

    $!builder.load(
        $!builder.inbounds_gep(
            %c<pmc_constants>,
            LLVM::Constant::integer(self._opcode_at($num, %c))
        )
    );
}

our method access_arg:type<sc> ($num, %c) {
    die("Wrong LHS mode") if %c<lhs>;

    $!debug && _dumper(%c<str_constants>);

    $!builder.load(
        $!builder.inbounds_gep(
            %c<str_constants>,
            LLVM::Constant::integer(self._opcode_at($num, %c))
        )
    );
}

our method access_arg:type<kic> ($num, %c) {
    LLVM::Constant::integer(self._opcode_at($num, %c));
}



=item process(PAST::Op)
Dispatch deeper.

our multi method process(PAST::Op $chunk, %c) {
    my $type := $chunk.pasttype // 'undef';
    my $sub  := pir::find_sub_not_null__ps('process:pasttype<' ~ $type ~ '>');
    $sub(self, $chunk, %c);
}

our method process:pasttype<inline> (PAST::Op $chunk, %c) {
    die("Can't handle 'inline' chunks");
}

our method process:pasttype<macro> (PAST::Op $chunk, %c) {
    my $name := $chunk.name // die("Strange macro");
    my $sub  := pir::find_sub_not_null__ps('process:macro<' ~ $name ~ '>');
    $sub(self, $chunk, %c);
}

our method process:pasttype<macro_define> (PAST::Op $chunk, %c) {
}


our method process:pasttype<macro_if> (PAST::Op $chunk, %c) {
}

our method process:pasttype<call> (PAST::Op $chunk, %c) {
    my $function := %!functions{ $chunk.name };

    if pir::defined($function) {
        $!debug && say("# Jitting { $chunk.name }");
        $!builder.call($function, |self.process_children($chunk, %c));
    }
    else {
        say("# Unknown function { $chunk.name }");
    }
}

our method process:pasttype<if> (PAST::Op $chunk, %c) {
    # Build ICmp by comparing value with 0.
    my $val  := self.process($chunk[0], %c);
    my $cond := $!builder.icmp(
        LLVM::INT_PREDICATE.NE,
        $val,
        LLVM::Constant::null(
            $val.typeof,
        ),
    );

    my $next_block := $!builder.get_insert_block.next();

    # Generate then/else/continue blocks.
    my $then_block := $next_block.insert_before("then");
    my $else_block := $next_block.insert_before("else");
    my $end_block  := $next_block.insert_before("endif");

    #$!builder.set_position($if_block);
    $!builder.cond_br($cond, $then_block, $else_block);

    $!builder.set_position($then_block);
    self.process($chunk[1], %c);
    $!builder.br($end_block) unless $!builder.get_insert_block.last_instruction.is_terminator_inst();

    # else is optional
    $!builder.set_position($else_block);
    self.process($chunk[2], %c) if $chunk[2];
    $!builder.br($end_block) unless $!builder.get_insert_block.last_instruction.is_terminator_inst();

    # Continue 
    $!builder.set_position($end_block);
}

our method process:pasttype<while> (PAST::Op $chunk, %c) {
}

our method process:pasttype<do-while> (PAST::Op $chunk, %c) {
}

our method process:pasttype<for> (PAST::Op $chunk, %c) {
}

our method process:pasttype<switch> (PAST::Op $chunk, %c) {
}

our method process:pasttype<undef> (PAST::Op $chunk, %c) {
    # TODO Handle .returns.
    my $pirop := $chunk.pirop;

    if $pirop {
        # Redispatch to process:pirop<foo>
        my $sub  := pir::find_sub_not_null__ps('process:pirop<' ~ $pirop ~ '>');
        $sub(self, $chunk, %c);
    }
    elsif $chunk.returns {
        self.process_children($chunk, %c)[0];
    }
    else {
    }
}

# Methods for pirop processing
our method process:pirop<=> (PAST::Op $chunk, %c) {
    # Switch processing to "lhs assignment".
    # This will disable "loading" of variables.
    %c<lhs>++;
    my $lhs := self.process($chunk[0], %c);
    %c<lhs>--;

    $!builder.store(
        self.process($chunk[1], %c) // die("Can't do it"),
        $lhs
    );
}

our method process:pirop<==> (PAST::Op $chunk, %c) {
    $!builder.icmp(
        LLVM::INT_PREDICATE.EQ,
        self.process($chunk[0], %c),
        self.process($chunk[1], %c)
    );
}

our method process:pirop<++> (PAST::Op $chunk, %c) {
    self._process_prefix_postfix($chunk, %c, 1);
}

our method process:pirop<--> (PAST::Op $chunk, %c) {
    self._process_prefix_postfix($chunk, %c, -1);
}

method _process_prefix_postfix (PAST::Op $chunk, %c, $delta) {
    %c<lhs>++;
    my $var   := self.process($chunk[0], %c);
    my $value := $!builder.load($var);
    %c<lhs>--;

    my $res := $!builder.add($value, LLVM::Constant::integer($delta)),
    $!builder.store($res, $var);

    # postfix uses previous value. reload var for prefix
    $chunk.name ~~ /postfix/ ?? $value !! $res;
}

our method process:pirop<arrow> (PAST::Op $chunk, %c) {
    my $old := +%c<lhs>;
    %c<lhs> := 0;
    my $lhs := self.process($chunk[0], %c);
    %c<lhs> := $old;

    $!debug && say("# pirop<arrow>");
    $!debug && _dumper($chunk[1]);
    $!debug && $lhs.dump();

    # XXX FIXME We have to choose field properly!!!
    my $res := $!builder.struct_gep($lhs, 0);
    $res.dump();

    $res;
}

our method process:pirop<!> (PAST::Op $chunk, %c) {
    $!debug && _dumper($chunk);

    $!builder.not( self.process($chunk[0], %c) );
}

our multi method process(PAST::Stmts $chunk, %c) {
    self.process($_, %c) for @($chunk);
}

our multi method process(PAST::Block $chunk, %c) {
    self.process($_, %c) for @($chunk);
}

our multi method process(String $str, %c) {
}


our method process:macro<goto_offset>(PAST::Op $chunk, %c) {
    my $offset;
    my $child := $chunk[0];
    if $child ~~ PAST::Val {
        $offset := ~$child.value;
    }
    elsif $child ~~ PAST::Var {
        if $child.scope eq 'register' {
            my $num  := $child.name;
            my $type := %c<op>.arg_type($num - 1);
            if $type == 'ic' {
                $offset := self._opcode_at($num, %c);
            }
        }
    }

    $!debug && say("# macro<goto_offset> '$offset' { %c<cur_opcode> }");
    my $target  := %c<cur_opcode> + $offset;
    my $jump_to := %c<basic_blocks>{$target}<bb>;

    pir::die("No target found") unless pir::defined($jump_to);
    pir::die("Crappy target") unless $jump_to ~~ LLVM::BasicBlock;

    # TODO Handle non-existing block.
    $!builder.br($jump_to);
}

our method process:macro<goto_address>(PAST::Op $chunk, %c) {
    $!debug && say("# macro<goto_address>");
    $!debug && _dumper($chunk[0]);
    # FIXME
    $!builder.store(
        self.process($chunk[0], %c),
        %c<variables><retval>,
    );
    $!builder.br(%c<leave>);
}

our method process:macro<expr_offset>(PAST::Op $chunk, %c) {
    LLVM::Constant::null(
        LLVM::Type::pointer(LLVM::Type::opcode_t())
    );
}

our method process:macro<expr_address>(PAST::Op $chunk, %c) {
    LLVM::Constant::null(
        LLVM::Type::pointer(LLVM::Type::opcode_t())
    );
}

method process_children(PAST::Op $chunk, %c) {
    # XXX .grep is temporaty solution for unhandled chunks.
    @($chunk).map(->$_{ self.process($_, %c) }).grep(->$_{ pir::defined($_) });
}


method _optimize(%c) {
    # Let's optimize it.
    my $pass := LLVM::PassManager.create(:optimize);
    $pass.run($!module);

    %c;
}


sub _dequote($str) {
    my $length := pir::length($str);
    pir::substr($str, 1, $length - 2);
}

=item opcode_at
Return opcode at offset.

method _opcode_at($offset, %ctx) {
    %ctx<bytecode>[%ctx<cur_opcode> + $offset];
}

method get_register(PAST::Var $var, %c) {
    my $num  := +$var.name - 1;
    my $type := %c<op>.arg_type($num);
    say("# type $type");
    if $type eq 'i' {
        self.get_int_reg($num, %c);
    }
    elsif $type eq 'n' {
        self.get_num_reg($num, %c);
    }
    elsif $type eq 's' {
        self.get_str_reg($num, %c);
    }
    elsif $type eq 'p' {
        self.get_str_reg($num, %c);
    }
    else {
        die("Horribly");
    }
}

# TODO Optimize it for direct access.
method get_int_reg($num, %c) {
    my $r := self._opcode_at($num, %c);
    my $n := ".I$r";
    self._lazy_load_register($n, $r, "Parrot_pcc_get_INTVAL_reg", %c);
    %c<variables>{$n};
}

method get_num_reg($num, %c) {
    my $r := self._opcode_at($num, %c);
    my $n := ".N$r";
    self._lazy_load_register($n, $r, "Parrot_pcc_get_FLOATVAL_reg", %c);
    %c<variables>{$n};
}

method get_str_reg($num, %c) {
    my $r := self._opcode_at($num, %c);
    my $n := ".S$r";
    self._lazy_load_register($n, $r, "Parrot_pcc_get_STRING_reg", %c);
    %c<variables>{$n};
}

method get_pmc_reg($num, %c) {
    my $r := self._opcode_at($num, %c);
    my $n := ".P$r";
    self._lazy_load_register($n, $r, "Parrot_pcc_get_PMC_reg", %c);
    %c<variables>{$n};
}

method _lazy_load_register($name, $r, $func, %c) {
    if ! %c<variables>{$name} {
        %c<variables>{$name} := $!builder.call(
            %!functions{$func},
            $!builder.load(%c<variables><interp>),
            $!builder.load(%c<variables><.CUR_CTX>),
            LLVM::Constant::integer($r),
            :name($name)
        );
    }
}



INIT {
    pir::load_bytecode("LLVM.pbc");
    pir::load_bytecode("nqp-setting.pbc");
}
# vim: ft=perl6

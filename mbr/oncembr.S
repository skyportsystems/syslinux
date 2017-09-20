/* -----------------------------------------------------------------------
 *
 *   Copyright 2007-2009 H. Peter Anvin - All Rights Reserved
 *   Copyright 2009 Intel Corporation; author: H. Peter Anvin
 *   Copyright 2017 Skyport Systems, Inc.
 *
 *   Permission is hereby granted, free of charge, to any person
 *   obtaining a copy of this software and associated documentation
 *   files (the "Software"), to deal in the Software without
 *   restriction, including without limitation the rights to use,
 *   copy, modify, merge, publish, distribute, sublicense, and/or
 *   sell copies of the Software, and to permit persons to whom
 *   the Software is furnished to do so, subject to the following
 *   conditions:
 *
 *   The above copyright notice and this permission notice shall
 *   be included in all copies or substantial portions of the Software.
 *
 *   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 *   EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
 *   OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 *   NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 *   HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 *   WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 *   FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 *   OTHER DEALINGS IN THE SOFTWARE.
 *
 * ----------------------------------------------------------------------- */

/*

Like mbr.S, this boot code boots a partition whose active flag is set.
This variant also allows the active partition to be overridden just for
one boot attempt, which is useful for implementing a failsafe operating
system upgrade.

- Bit 6 in a partition's active field (0x40) means boot once; when set,
  clear the bit and write the partition table back to disk, then try to
  boot the partition; if there is no boot-once partition, use the normal
  active flag in bit 7 (0x80) to decide which partition to boot.
- If more than one partition has the boot-once active flag set, the first
  one discovered is booted; likewise for the normal active flag.
- BIOS must support Enhanced Disk Drive Services read and write functions
  (INT 13h AH=42h/43h); old-fashioned CHS functions are not supported.

*/

#include "adjust.h"

	.code16
	.text

	.globl	bootsec
stack		= 0x7c00
driveno		= (stack-6)
active		= (stack-8)

BIOS_kbdflags	= 0x417
BIOS_page	= 0x462

	/* gas/ld has issues with doing this as absolute addresses... */
	.section ".bootsec", "a", @nobits
	.globl	bootsec
bootsec:
	.space	512

	.text
	.globl	_start
_start:
	.byte	0x33, 0xc0	/* xorw	%ax, %ax */
	cli
	movw	%ax, %ds
	movw	%ax, %ss
	movw	$stack, %sp
	movw	%sp, %si
	pushw	%es		/* es:di -> $PnP header */
	pushw	%di
	movw	%ax, %es
	sti
	cld

	/* Copy down to 0:0x600 */
	movw	$_start, %di
	movw	$(512/2), %cx
	rep; movsw

	ljmpw	$0, $next
next:

	ADJUST_DRIVE
	pushw	%dx		/* dl -> drive number */
	pushw	$0x40		/* boot-once active flag */

	xorl	%eax, %eax	/* Base */
	cdq			/* Root (%edx <- 0) */
	call	scan_partition_table

	movw	$0x80, (active) /* normal active flag */
	call	scan_partition_table

	/* If we get here, we have no OS */
missing_os:
	call	error
	.ascii	"Missing operating system.\r\n"

/*
 * rw_bootsec: read/write boot sector from/to disk at sector %eax.
 * %cx is the int 13h function (0x4200 for read, 0x4300 for write).
 * CF is set on error.  All registers saved.
 */
rw_bootsec:
	pushal
	xorl	%edx, %edx
	movw	$bootsec, %bx
	pushl	%edx	/* MSW of LBA */
	pushl	%eax	/* LSW of LBA */
	pushw	%es	/* Buffer segment */
	pushw	%bx	/* Buffer offset */
	pushw	$1	/* Sector count */
	pushw	$16	/* Size of packet */
	movw	%sp, %si
	movw	%cx, %ax
	movb	(driveno), %dl
	int	$0x13
	leaw	16(%si), %sp	/* Drop DAPA */
	popal
	ret

/*
 * read_partition_table:
 *	Read a partition table (pointed to by %eax), and copy
 *	the partition table into the ptab buffer.
 *
 *	Clobbers %si, %di, and %cx, other registers preserved.
 *	%cx = 0 on exit.
 *
 *	On error, CF is set and ptab is overwritten with junk.
 */
ptab	= _start+446

read_partition_table:
	movw	$0x4200, %cx
	call	rw_bootsec
	movw	$bootsec+446, %si
	movw	$ptab, %di
	movw	$(16*4/2), %cx
	rep ; movsw
	ret

/*
 * write_partition_table:
 *	Write partition table from the ptab buffer to disk at LBA
 *	%eax.
 *
 *	Clobbers %si, %di, and %cx, other registers preserved.
 *
 *	On error, CF is set.
 */
write_partition_table:
	movw	$ptab, %si
	movw	$bootsec+446, %di
	movw	$(16*4/2), %cx
	rep ; movsw
	movw	$0x4300, %cx
	call	rw_bootsec
	ret

/*
 * scan_partition_table:
 *	Scan a partition table currently loaded in the partition table
 *	area.  Preserve all registers.
 *
 *      On entry:
 *	  %eax - base (location of this partition table)
 *	  %edx - root (offset from MBR, or 0 for MBR)
 *
 *      These get pushed into stack slots:
 *        28(%bp) - %eax - base
 *	  20(%bp) - %edx - root
 */

scan_partition_table:
	pushal
	movw	%sp, %bp

	/* Search for active partitions */
	movw	$ptab, %bx
	movw	$4, %cx
	push	%bx
	push	%cx
	movw	(active), %dx
5:
	testb	%dl, (%bx)
	jz	6f
	movw	%bx, %si
	jmp	boot
6:
	addw	$16, %bx
	loopw	5b

	/* No active partitions found, look for extended partitions */
	popw	%cx		/* %cx <- 4    */
	popw	%bx		/* %bx <- ptab */
7:
	movb	4(%bx), %al
	cmpb	$0x0f, %al	/* 0x0f = Win9x extended */
	je	8f
	andb	$~0x80, %al	/* 0x85 = Linux extended */
	cmpb	$0x05, %al	/* 0x05 = MS-DOS extended */
	jne	9f

	/* It is an extended partition.  Read the extended partition and
	   try to scan it.  If the scan returns, re-load the current
	   partition table and resume scan. */
8:
	movl	8(%bx), %eax		/* Partition table offset */
	movl	20(%bp), %edx		/* "Root" */
	addl	%edx, %eax		/* Compute location of new ptab */
	andl	%edx, %edx		/* Is this the MBR? */
	jnz	10f
	movl	%eax, %edx		/* Offset -> root if this was MBR */
10:
	pushw	%cx
	call	read_partition_table
	jc	11f
	call	scan_partition_table
11:
	/* This returned, so we need to reload the current partition table */
	movl	28(%bp), %eax		/* "Base" */
	call	read_partition_table
	popw	%cx

	/* fall through */
9:
	/* Not an extended partition */
	addw	$16, %bx
	loopw	7b

	/* Nothing found, return */
	popal
	ret

/*
 * boot: invoke the actual bootstrap. (%si) points to the partition
 *	 table entry, and 28(%bp) has the partition table base.
 */
boot:
	cmpb	$0x40, (active)
	jne	3f

	/* Boot-once mode, clear the flag and write the partition table back
	   to disk */
	andb	$~0x40, (%si)
	pushw	%si
	movl	28(%bp), %eax
	call	write_partition_table
	popw	%si
3:
	movl	8(%si), %eax
	addl	28(%bp), %eax
	movl	%eax, 8(%si)	/* Adjust in-memory partition table entry */
	movw	$0x4200, %cx
	call	rw_bootsec
	jc	disk_error

	/* Check if the read sector is a XFS superblock */
	cmpl	$0x42534658, (bootsec) /* "XFSB" */
	jne	no_xfs

	/* We put the Syslinux boot sector at offset 0x800 (4 sectors), so we
	 * need to adjust %eax (%eax + 4) to read the right sector into 0x7C00.
	 */
	addl	$0x800 >> 0x09, %eax /* plus 4 sectors */
	call	rw_bootsec
	jc	disk_error

no_xfs:
	cmpw	$0xaa55, (bootsec+510)
	jne	missing_os		/* Not a valid boot sector */
	movw	$driveno, %sp	/* driveno == bootsec-6 */
	popw	%dx		/* dl -> drive number */
	popw	%di		/* es:di -> $PnP vector */
	popw	%es
	cli
	jmpw	*%sp		/* %sp == bootsec */

disk_error:
	call	error
	.ascii	"Operating system load error.\r\n"

/*
 * Print error messages.  This is invoked with "call", with the
 * error message at the return address.
 */
error:
	popw	%si
2:
	lodsb
	movb	$0x0e, %ah
	movb	(BIOS_page), %bh
	movb	$0x07, %bl
	int	$0x10		/* May destroy %bp */
	cmpb	$10, %al	/* Newline? */
	jne	2b

	int	$0x18		/* Boot failure */
die:
	hlt
	jmp	die

# Native tools use the driver/model loop timer; Icarus uses process wall time.
BEGIN { FS="\t"; simulators[1]="arcilator"; simulators[2]="verilator"; simulators[3]="iverilog" }
$1=="sim" { next }
NF==6 {
  key=$2 SUBSEP $1
  duration=($5=="-" ? $6 : $5)
  if (duration<=0) { print "invalid duration in " FILENAME > "/dev/stderr"; exit 1 }
  sample[key,++count[key]]=duration
  cycles[key]=$4
  tests[$2]=1
}
function median(key, i,j,tmp) {
  for(i=1;i<=count[key];i++)
    for(j=i+1;j<=count[key];j++)
      if(sample[key,i]>sample[key,j]) {
        tmp=sample[key,i];sample[key,i]=sample[key,j];sample[key,j]=tmp
      }
  i=int(count[key]/2)+1
  return count[key]%2 ? sample[key,i] : (sample[key,i-1]+sample[key,i])/2
}
END {
  print "| Program | arcilator (loop) | Verilator (loop) | Icarus (wall) |"
  print "| --- | ---: | ---: | ---: |"
  for(test in tests) {
    printf "| %s |",test
    for(s=1;s<=3;s++) {
      key=test SUBSEP simulators[s]
      if(count[key]) printf " %.0f cycles/s |",cycles[key]/median(key)
      else printf " - |"
    }
    print ""
  }
  print "\nMedian after one warm-up. Each row compares the same binary and cycle count."
}

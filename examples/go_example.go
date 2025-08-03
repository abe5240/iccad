// Minimal Go workload for Int64Profiler
package main

import "fmt"

func main() {
	var add, sub, mul, div uint64 = 1, 100, 3, 3
	for i := 0; i < 100000; i++ {
		add += uint64(i)
		sub -= uint64(i)
		mul *= 2
		div /= 2
	}
	fmt.Println("dummy:", add+sub+mul+div)
}

DMA_PIO_APP=dma_pio_app
PIO_TEST=pio_test

all:
	gcc  $(DMA_PIO_APP).c -lpthread -o $(DMA_PIO_APP)
	gcc  $(PIO_TEST).c    -lpthread -o $(PIO_TEST)
clean:
	rm $(DMA_PIO_APP) $(PIO_TEST) -rf
		

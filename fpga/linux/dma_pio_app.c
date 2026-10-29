#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdbool.h>
#include <fcntl.h> 
#include <sys/ioctl.h> 
#include <time.h>
#include <pthread.h>
#include <sys/mman.h>
#include <sys/time.h>
#include <stdlib.h>
#include <sys/time.h>
#include<pthread.h>

#define NO_TEST														/* 代码功能测试时打开注释 */
#define DEBUG
/* 宽间距为了兼容低版本，部件尺寸标准不一致 */
//#define WIDGET_SPACE													/* 部件间距，宏定义打开表示为宽松；注释掉表示间距紧凑 */

#define PCIE_DRIVER_FILE_PATH 			"/dev/pango_pci_driver"			/* pcie驱动文件目录 */
#define MEM_FILE_PATH 					"/dev/mem"						/* mem驱动文件目录 */
#define VEISION 						"Pango PCIe Test v1.0"			/* 软件测试版本信息 */

#define TYPE 'S'
#define PCI_READ_DATA_CMD    			_IOWR(TYPE, 0, int)							/* 读数据指令 */
#define PCI_WRITE_DATA_CMD    			_IOWR(TYPE, 1, int)							/* 写数据指令 */
#define PCI_MAP_ADDR_CMD    			_IOWR(TYPE, 2, int)							/* DMA总线地址映射 */
#define PCI_WRITE_TO_KERNEL_CMD    		_IOWR(TYPE, 3, int)							/* 写内核数据操作 */
#define PCI_DMA_READ_CHECK    			_IOWR(TYPE, 4, int)							/* DMA读操作 */
#define PCI_DMA_WRITE_CHECK    			_IOWR(TYPE, 5, int)							/* 查询DMA写操作是否完成 */
#define PCI_READ_FROM_KERNEL_CMD    	_IOWR(TYPE, 6, int)							/* 读取内核数据操作 */
#define PCI_UMAP_ADDR_CMD    			_IOWR(TYPE, 7, int)							/* 释放映射地址 */
#define PCI_READ_RAM_CMD           		_IOWR(TYPE, 8, int)							/* 读ram指令 */
#define PCI_MAP_BAR0_CMD           		_IOWR(TYPE, 9, int)							/* MAP BAR0 指令 */


#define MAX_BLOCK_SIZE   				1024							/* 位流分块缓存区最大值 */
#define LINK_OK							0x11							/* PCI链接成功，返回值 bit[4:0]*/
#define CRC_OK							0xa00							/* 位流加载完成后，校验成功返回值 bit[11:8]*/
#define CRC_ERROR						0xe00							/* 位流加载完成后，校验错误返回值 bit[11:8]*/
#define CRC_REPEAT						0xf00							/* 位流加载完成后，重新读取校验返回值 bit[11:8]*/
#define AXI_CONNECT_USER				0xa								/* AXI链接用户接口配置值 bit[3:0]*/
#define AXI_CONNECT_SWITCH				0xf								/* AXI链接转换接口配置值 bit[3:0]*/
#define LOAD_DATA_FINISH        		0xa0							/* 位流加载成功返回值 bit[7:4]*/
#define LOAD_DATA_UNFINISH				0x00							/* 位流正在加载返回值 bit[7:4]*/
#define BAR_OFFSET_1					0x00							/* 读取PCI状态地址偏移地址 */
#define BAR_OFFSET_2					0x10							/* 配置PCI加载偏移地址 */
#define BAR_OFFSET_3					0x20							/* 加载位流偏移地址 */
#define PEFORMANCE_STATUS_OFFSET		0x00							/* 性能测试状态寄存器 */
#define PEFORMANCE_WRITE_CNT_OFFSET		0x04							/* 性能测试DMA写计数 */	
#define PEFORMANCE_READ_CNT_OFFSET		0x08							/* 性能测试DMA读计数 */	
#define PEFORMANCE_ERROR_CNT_OFFSET		0x0c							/* 性能测试错误计数 */	
#define PEFORMANCE_DATA_CNT_OFFSET		0x10							/* 性能测试数据包计数 */	

#define PAGE_ROUND_DOWN(x)				((x) & ~(getpagesize() - 1))
#define PAGE_ROUND_UP(x)				(PAGE_ROUND_DOWN((x) + getpagesize() - 1))
#define file_len(len)					((len)%4 == 0 ? (len)/4 : ((len)/4)+1)
#define BOOL_SWITCH(flag)  				(((flag) == TRUE) ? FALSE : TRUE)
#define DMA_MAX_PACKET_SIZE   			4096							/* DMA包最大值 */
#define DMA_MIN_PACKET_SIZE   			4								/* DMA包最小值 */

#define BAR0_MAX                       0x500

int pci_driver_fd = -1;													/* PCIe驱动文件描述符 */
char *bit_file_name = NULL;
char *dma_write_file_name = NULL;
char *button_info = NULL;
char write_buf[BAR0_MAX];
char read_buf[BAR0_MAX];
int fd;
void *mem_pio_addr =NULL;
int pio_test_num = 1;
int dma_test_num = 1;
int time_out =0;
int pio_addr=0;

long num=0;
int crc_check=0;

char write_dma_buf[DMA_MAX_PACKET_SIZE];
char read_dma_buf[DMA_MAX_PACKET_SIZE];

typedef enum _OPERATION_NUM_
{
	write_num = 0,
	read_num,
	w_r_num,
	info_num,
	tandem_num,
	performance_num
}op_num;

enum bar_num
{
	Bar0 = 0,
	Bar1,
	Bar2,
	Bar3,
	Bar4,
	Bar5
};

typedef struct _BAR_INFO_
{
	unsigned long bar_base;
	unsigned long bar_len;
}BAR_BASE_INFO;

typedef struct _CAP_INFO_
{
	unsigned char flag;
	unsigned char id;
	unsigned char addr_offset;
	unsigned char next_offset;
}CAP_INFO;

typedef struct _CAP_LIST_
{
	unsigned char cap_status;
	unsigned char cap_error;
	CAP_INFO cap_buf[256];
}CAP_LIST;

typedef struct _PCI_INFO_
{
	unsigned int vendor_id;
	unsigned int device_id;
	unsigned int cmd_reg;
	unsigned int status_reg;
	unsigned int revision_id;
	unsigned int class_prog;
	unsigned int class_device;
	BAR_BASE_INFO bar[6];
	unsigned int min_gnt;
	unsigned int max_lat;
	unsigned int link_speed;
	unsigned int link_width;
	unsigned int mps;
	unsigned int mrrs;
	unsigned int data[1024];
}PCI_DEVICE_INFO;

typedef struct _LOAD_DATA_
{
	unsigned int num_words;
	unsigned int block_words[MAX_BLOCK_SIZE];	
}LOAD_DATA_INFO;

typedef struct _PCI_LOAD_
{
	unsigned char link_status;
	unsigned int  crc;
	unsigned char axi_direction;
	unsigned char load_status;
	unsigned int total_num_words;
	LOAD_DATA_INFO data_block;
}PCI_LOAD_INFO;


typedef struct _COMMAND_
{
	unsigned char w_r;
	unsigned char step;
	unsigned int addr;
	unsigned int data;
	unsigned int cnt;
	unsigned int delay;
	PCI_DEVICE_INFO get_pci_dev_info;
	CAP_LIST cap_info;
	PCI_LOAD_INFO load_info;
}COMMAND_OPERATION;


COMMAND_OPERATION command_operation;

typedef struct _CONFIG_
{
	unsigned int addr;
	unsigned int data;
}CONFIG_OPERATION;

COMMAND_OPERATION config_operation;


typedef struct _FILE_INFO_
{
	FILE* _pg_load_file;
	unsigned int *file_data_buffer;
	unsigned int file_total_bytes;
	unsigned int file_total_dws;
	unsigned int file_blocks_integer;
	unsigned int file_blocks_remainder;
}FILE_INFO;

FILE_INFO load_file_info;
FILE_INFO dma_write_file_info;




typedef struct _ENTRY_INFO_
{
	int num;
	int id;
}ENTRY_INFO;

typedef struct _HANDLER_ID_
{
	ENTRY_INFO pio;
	ENTRY_INFO config;
	ENTRY_INFO start;
	ENTRY_INFO end;
	ENTRY_INFO alloc_mem;
	ENTRY_INFO offset_addr;
	ENTRY_INFO data_length;
	ENTRY_INFO packet_size;
}HANDLER_ID;

typedef struct _DEV_MEM_
{
	off_t offset;
	size_t len;
	void *vaddr;
} DEV_MEM;

DEV_MEM map_dev_mem = {0, 0, NULL};

typedef struct _PIO_PAGE_INFO_
{
	unsigned char bar;
	unsigned char w_r;
	unsigned int addr;
	unsigned int data;
	unsigned int cnt;
	unsigned int delay;
}PIO_INFO;

PIO_INFO pio_page_info;

typedef struct _BUTTON_FLAG_
{
	bool free_time;
	bool pio;
	bool dma_auto;
	bool close_file;
	bool manual_start;
	bool performance_start;
}BUTTON_FLAG;


typedef struct _ID_
{
	unsigned char id;
	unsigned char *id_info;
}ID_INFO;

typedef struct _DMA_DATA_
{
	unsigned char read_buf[DMA_MAX_PACKET_SIZE];
	unsigned char write_buf[DMA_MAX_PACKET_SIZE];
}DMA_DATA;

typedef struct _DMA_OPERATION_
{
	unsigned int current_len;
	unsigned int offset_addr;
	unsigned int cmd;
	DMA_DATA data;
}DMA_OPERATION;

DMA_OPERATION dma_operation;

typedef struct _DMA_AUTO_
{
	unsigned int test_num;
	unsigned int start;
	unsigned int end;
	unsigned int step;
	unsigned int write_cnt;
	unsigned int read_cnt;
	unsigned int error_cnt;
	unsigned int step_add_cnt;
}DMA_AUTO;

DMA_AUTO dma_auto_info;


typedef struct _DMA_MANUAL_
{
	unsigned int allocate_mem_size;
	unsigned int offset_addr;
	unsigned int data_length;
}DMA_MANUAL;

DMA_MANUAL dma_manual_info;

typedef struct _PERFORMANCE_OPERATION_
{
	unsigned int current_len;
	unsigned int cmd;
	unsigned char cmp_flag;
}PERFORMANCE_OPERATION;

PERFORMANCE_OPERATION performance_operation;

typedef struct _PERFORMANCE_DATA_
{
	float w_throughput;
	float r_throughput;
	float w_bandwidth;
	float r_bandwidth;
	unsigned char dma_w_status;
	unsigned char dma_r_status;
	unsigned char busy_w_status;
	unsigned char busy_r_status;
	unsigned int w_total_cnt;
	unsigned int w_invalid_cnt;
	unsigned int w_error_cnt;
	unsigned int r_total_cnt;
	unsigned int r_invalid_cnt;
	unsigned int r_error_cnt;
}PERFORMANCE_DATA;

PERFORMANCE_DATA performance_data;


int open_pci_driver(void)
{
	int fd;
	
	fd = open(PCIE_DRIVER_FILE_PATH, O_RDWR);
	
	if(fd < 0)
	{
		perror("open fail\n");
		return -1;
	}
	return fd;
}

void *map_mem(unsigned long addr, unsigned int size, DEV_MEM *map_mem)
{
	int fd = -1;
	void *vaddr = NULL;
	off_t offset;
	size_t len;
	if(map_mem->vaddr != NULL)
	{
		printf("Bar0 is busy, please release it first\n");
		return vaddr;
	}

	offset = PAGE_ROUND_DOWN(addr);
	len    = PAGE_ROUND_UP(size);
	if ((offset == map_mem->offset) && (len == map_mem->len))
		return map_mem->vaddr;

	fd = open(MEM_FILE_PATH, O_RDWR | O_SYNC);
	if(fd < 0) 
	{
		printf("open '%s' failed !!!\n", MEM_FILE_PATH);
	}
	else
	{
		vaddr = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, offset);
		close(fd);
	}
	if ((vaddr == NULL) || (vaddr == MAP_FAILED)) 
	{
		printf("mmap '%s' failed !!!\n", MEM_FILE_PATH);
	}
	else
	{
		map_mem->len 	= len;
		map_mem->offset = offset;
		map_mem->vaddr 	= vaddr;
	}
	return vaddr;
}

COMMAND_OPERATION cmd_op ={};

DMA_OPERATION *dma_oper = &dma_operation;



int attach_cpu(int cpu_index)
{
	
    int cpu_num = sysconf(_SC_NPROCESSORS_CONF);
    if (cpu_index < 0 || cpu_index >= cpu_num)
    {
        printf("cpu index ERROR!\n");
        return -1;
    }
    
    cpu_set_t mask;
    CPU_ZERO(&mask);
    CPU_SET(cpu_index, &mask);

    if (pthread_setaffinity_np(pthread_self(), sizeof(mask), &mask) < 0)
    {
        printf("set affinity np ERROR!\n");
        return -1;
    }

    return 0;
}





/************************************************************************************
	bar0_map_ram_test
	操作bar0，在fpga内部bar0映射到ram中，由于ram 位宽 16, 但 bar0数据位宽是 1个字节，但bar操作是偏移4字节操作。
	因此FPGA内部做了转换，每次操作bar 4个字节。FPGA内部将数据拆分存储。即
	bar0  0x0~0x3   =  ram 0x0 ~ 0x1 
	bar0  0x4~0x7   =  ram 0x2 ~ 0x3 
	bar0  0x8~0x11  =  ram 0x4 ~ 0x5 
	

*************************************************************************************/

void *thread_func1(void *ptr)
{
	int j,i;
	struct timeval starttime,endtime;
	long timeuse;
	long recv_write_time=0;
	long recv_read_time=0;
	unsigned int write_data =0;
	unsigned int read_data  =0;

	attach_cpu(0);
	printf("pio number test start\n");
	mem_pio_addr = map_mem(cmd_op.get_pci_dev_info.bar[0].bar_base , BAR0_MAX , &map_dev_mem);

    	for(j = 0 ; j < pio_test_num  ; j++)
	{
		write_data = rand();
		*((unsigned int *)mem_pio_addr + pio_addr  + j%BAR0_MAX ) = write_data  ;
		
		read_data  =  *((unsigned int *)mem_pio_addr + pio_addr + j%BAR0_MAX) ;
		
		if(write_data != read_data )
			printf("PIO ERR test_num j=%d  wirte 0x%x read 0x%x \n",j,write_data,read_data);
	} 


	printf("PIO test num %d  end\n",pio_test_num);
	//printf("mem write %d MAX average time %lf us \n",BAR0_MAX,(float)recv_write_time );
	//printf("mem read  %d MAX average time %lf us \n\n",BAR0_MAX,(float)recv_read_time );
	
	
}


void *time_thread_func1(void *ptr)
{
	long j=0,i;
	struct timeval starttime,endtime;
	long timeuse;
	long recv_write_time=0;
	long recv_read_time=0;
	unsigned int write_data =0;
	unsigned int read_data  =0;

	printf("pio time test start\n");
	attach_cpu(0);
	mem_pio_addr = map_mem(cmd_op.get_pci_dev_info.bar[0].bar_base , BAR0_MAX , &map_dev_mem);


	while(time_out)
	{
		write_data = rand();
		//gettimeofday(&starttime,0);	   
		*((unsigned int *)mem_pio_addr + pio_addr  +  (j%BAR0_MAX) ) = write_data  ;
		//gettimeofday(&endtime,0);
		
		//timeuse  = 1000000*(endtime.tv_sec - starttime.tv_sec) + endtime.tv_usec - starttime.tv_usec ;
		//if(timeuse > recv_write_time)
		//	recv_write_time = timeuse;
		
		
		//gettimeofday(&starttime,0);	
		read_data  =  *((unsigned int *)mem_pio_addr + pio_addr + (j % BAR0_MAX)) ;
		//gettimeofday(&endtime,0);
		//timeuse  = 1000000*(endtime.tv_sec - starttime.tv_sec) + endtime.tv_usec - starttime.tv_usec ;
		//if(timeuse > recv_read_time)
		//	recv_read_time = timeuse;
		
		if(write_data != read_data )
			printf("PIO ERR test_num j=%ld  wirte 0x%x read 0x%x \n",j,write_data,read_data);
		
		j++;
		
	} 


	printf("PIO test num %ld  end \n",j);
	//printf("mem write %d MAX average time %lf us \n",BAR0_MAX,(float)recv_write_time );
	//printf("mem read  %d MAX average time %lf us \n\n",BAR0_MAX,(float)recv_read_time );
	fflush(stdout);
	
}



void * thread_func2(void *ptr)
{
	int len ;
	int i;
	struct timeval starttime,endtime;
	long timeuse=0;
	long recv_write_time=0;
	long recv_read_time=0;
 	int k;	
	
	printf("dma number test start\n");
	attach_cpu(1);
	
	ioctl(fd, PCI_MAP_ADDR_CMD, dma_oper);						/* DMA 地址映射,以及数据缓存申请 */
	
	
	for(i = 0 ; i < DMA_MAX_PACKET_SIZE / 4 ; i++)
		*((unsigned int *)write_dma_buf + i) =rand() ;
	
	for (k = 0 ; k < dma_test_num ; k++)
	{	
		memset(read_dma_buf,0,dma_oper->current_len);

		lseek(fd,dma_oper->offset_addr, SEEK_CUR);
		
		gettimeofday(&starttime,0);
	    len = write(fd,write_dma_buf,dma_oper->current_len);
		if(len != dma_oper->current_len)
		{
			printf("write data ERR \n");
			return NULL;
		}
		gettimeofday(&endtime,0);
		
		timeuse  = 1000000*(endtime.tv_sec - starttime.tv_sec) + endtime.tv_usec - starttime.tv_usec ;
		if(timeuse > recv_write_time)
			recv_write_time = timeuse;
		
		
		gettimeofday(&starttime,0);
		len = read (fd,read_dma_buf,dma_oper->current_len);
		if(len != dma_oper->current_len)
		{
			printf("read data ERR len %d \n",len);
			return NULL;
		}
		gettimeofday(&endtime,0);
		
		timeuse  = 1000000*(endtime.tv_sec - starttime.tv_sec) + endtime.tv_usec - starttime.tv_usec;
		if(timeuse > recv_read_time)
			recv_read_time = timeuse;

		if(!crc_check)
			for(i = 0 ; i <  dma_oper->current_len ; i ++)
			{
				if(read_dma_buf[i] != write_dma_buf[i])
				{
					printf("DMA_test_num ERR =%d ERR_BYTE=%d wirte 0x%x  read 0x%x \n",k,i,(unsigned char )write_dma_buf[i],(unsigned char )read_dma_buf[i]);
					
				}	
			}

	}
	
	printf("DMA dma test_num %d  end \n",dma_test_num);
	printf("DMA write MAX_time %ld us\n",recv_write_time);
	printf("DMA read  MAX_time %ld us\n\n",recv_read_time);
	
	ioctl(fd, PCI_UMAP_ADDR_CMD, dma_oper);						/* 释放数据缓存 */
	
}


void * time_thread_func2(void *ptr)
{
	int len ;
	int i;
	struct timeval starttime,endtime;
	long timeuse=0;
	long recv_write_time=0;
	long recv_read_time=0;
 	int k;	
	long test_num =0;
	attach_cpu(1);
	
	ioctl(fd, PCI_MAP_ADDR_CMD, dma_oper);						/* DMA 地址映射,以及数据缓存申请 */
	
	printf("DMA time test start\n");
	
	for(i = 0 ; i < DMA_MAX_PACKET_SIZE / 4 ; i++)
		*((unsigned int *)write_dma_buf + i) =rand()  ;
	
	while(time_out)
	{
		memset(read_dma_buf,0,dma_oper->current_len);

		lseek(fd,dma_oper->offset_addr, SEEK_CUR);
		
		gettimeofday(&starttime,0);
	    	len = write(fd,write_dma_buf,dma_oper->current_len);
		if(len != dma_oper->current_len)
		{
			printf("write data ERR \n");
			return NULL;
		}
		gettimeofday(&endtime,0);
		
		timeuse  = 1000000*(endtime.tv_sec - starttime.tv_sec) + endtime.tv_usec - starttime.tv_usec ;
		if(timeuse > recv_write_time)
			recv_write_time = timeuse;
		
		
		gettimeofday(&starttime,0);
		len = read (fd,read_dma_buf,dma_oper->current_len);
		if(len != dma_oper->current_len)
		{
			printf("read data ERR len %d \n",len);
			return NULL;
		}
		gettimeofday(&endtime,0);
		
		timeuse  = 1000000*(endtime.tv_sec - starttime.tv_sec) + endtime.tv_usec - starttime.tv_usec;
		if(timeuse > recv_read_time)
			recv_read_time = timeuse;

		if(!crc_check)
			for(i = 0 ; i <  dma_oper->current_len ; i ++)
			{
				if(read_dma_buf[i] != write_dma_buf[i])
				{
					printf("DMA_test_num ERR =%ld ERR_BYTE=%d wirte 0x%x  read 0x%x \n",test_num,i,(unsigned char )write_dma_buf[i],(unsigned char )read_dma_buf[i]);
					
				}	
			}
		test_num ++;
	}
	
	printf("DMA dma test_num %ld end \n",test_num);
	printf("DMA write MAX_time %ld us\n",recv_write_time);
	printf("DMA read  MAX_time %ld us\n\n",recv_read_time);
   	fflush(stdout);	
	ioctl(fd, PCI_UMAP_ADDR_CMD, dma_oper);						/* 释放数据缓存 */
	
}


int main(int argc,char*argv[])
{

    pthread_t t1, t2;
    pthread_attr_t attr1, attr2; 
    struct sched_param sch1, sch2;
	int start_DMA_t =0;
	int start_PIO_t =0;
	int time_test_flag =0;
	int time_num=0;
	int test_time = 1;

	fd = open_pci_driver();
	if(fd < 0)
	{
		return -1;
	}
	
	ioctl(fd, PCI_MAP_BAR0_CMD, &cmd_op);						/*获取 bar0 地址映射 */

	dma_oper->offset_addr = 0x1000;	
	dma_oper->current_len = 1024;

	int optch = 0;
	while((optch = getopt(argc, argv, "hd:p:a:l:c:d:n:t:o:")) != -1)
	{
        // printf("optind: %d\n", optind); //下一个检索位置，即选项的参数位置
		switch (optch)
		{
			case 'a':
				//printf("-a %s\n", optarg);
				dma_oper->offset_addr =  atol(optarg);
				break;
			case 'l':
				dma_oper->current_len =  atol(optarg);
				if(dma_oper->current_len > 4096)
				{
					printf("test len ERR ,MAX 4096\n");
				}
				break;
			case 'c':
				crc_check =  atol(optarg);
				break;
			case 'd':
				start_DMA_t = 1; //启动DMA测试
				dma_test_num = atol(optarg);
				printf("only DMA test \n\n");				
				break;
			case 'p':
				start_PIO_t = 1; //启动 PIO测试
				pio_test_num = atol(optarg);
				printf("only PIO test \n\n");
				//printf("pio_test_num %d \n",pio_test_num);
				break;
			case 't':
				test_time = atol(optarg);
				time_test_flag = 1;
				printf("time test ,pio and dma\n\n");
				break; 
			case 'o':
				pio_addr = atol(optarg);
				break;			
			case 'h':
				printf("-a xxx (0xd), dma to ram addr \n");
				printf("-l xxx (0xd), dma to ram len \n");
				printf("-p xxx (0xd), only pio test \n");
				printf("-o xxx (0xd), pio to ram addr\n");
				printf("-d xxx (0xd), only dma test \n");
				printf("-t xxx (0xd), time test num,dma and pio\n");
				return 0;
		}
	}
	
	
	srand(time(0));

	
    pthread_attr_init(&attr1);
    pthread_attr_init(&attr2);
	
  
    sch1.sched_priority = 90;
    sch2.sched_priority = 90;
	
	
	pthread_attr_setinheritsched(&attr1, PTHREAD_EXPLICIT_SCHED);
	pthread_attr_setinheritsched(&attr2, PTHREAD_EXPLICIT_SCHED);

	pthread_attr_setschedpolicy(&attr1, SCHED_FIFO);
	pthread_attr_setschedpolicy(&attr2, SCHED_FIFO);

	pthread_attr_setschedparam(&attr1, &sch1);
	pthread_attr_setschedparam(&attr2, &sch2);

	if(time_test_flag)
	{
    	printf("len = %d ,dma_test_num  %d test_addr 0x%x  \n",dma_oper->current_len,dma_test_num,dma_oper->offset_addr);
		time_out = 1;
		pthread_create(&t1, &attr1, time_thread_func1,NULL);
		pthread_create(&t2, &attr2, time_thread_func2, NULL);
		while(1)
		{
			time_num++;
			sleep(1);
			if(time_num >= test_time)
			{
				time_out =0;
				break;
			}
		}
	}
	else
	{
		if(start_PIO_t)
		{
			printf("pio test pio_addr 0x%x \n",pio_addr);
			pthread_create(&t1, &attr1, thread_func1,NULL);
		}	
		if(start_DMA_t)
		{
			
    			printf("len = %d ,dma_test_num  %d test_addr 0x%x  \n",dma_oper->current_len,dma_test_num,dma_oper->offset_addr);
			pthread_create(&t2, &attr2, thread_func2, NULL);
		}
	}


	if(start_PIO_t)
		pthread_join(t1, NULL);
	
	if(start_DMA_t)
		pthread_join(t2, NULL);
	

	sleep(1);

	return 0;
}


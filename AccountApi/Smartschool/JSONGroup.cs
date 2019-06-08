using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountApi.Smartschool
{
    internal class JSONGroup
    {
        public string Id { get; set; }
        public string Code { get; set; }
        public string Name { get; set; }
        public string Desc { get; set; }
        public bool IsKlas { get; set; }
        public bool IsOfficial { get; set; }
    }
}

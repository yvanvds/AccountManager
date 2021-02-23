using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.DirectoryServices;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountApi.Directory
{
    public class ADGroup
    {
        public string DN;
        public string CN;

        public ADGroup(DirectoryEntry entry) {
            CN = entry.Properties.Contains("cn") ? entry.Properties["cn"].Value.ToString() : "";
            DN = entry.Properties.Contains("distinguishedName") ? entry.Properties["distinguishedName"].Value.ToString() : "";
        }

        public ADGroup(JObject obj)
        {
            DN = obj.ContainsKey("dn") ? obj["dn"].ToString() : "";
            CN = obj.ContainsKey("cn") ? obj["cn"].ToString() : ""; 
        }

        public JObject ToJson()
        {
            var result = new JObject
            {
                ["dn"] = DN,
                ["cn"] = CN,
            };
            return result;
        }


    }
}

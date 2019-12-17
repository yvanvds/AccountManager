using Newtonsoft.Json;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountApi.Azure
{
    public class User
    {
        [JsonProperty("id")]
        public string ID { get; set; }
        
        [JsonProperty("displayName")]
        public string DisplayName { get; set; }

        [JsonProperty("givenName")]
        public string GivenName { get; set; }

        [JsonProperty("surName")]
        public string SurName { get; set; }

        [JsonProperty("mail")]
        public string Mail { get; set; }

        [JsonProperty("userPrincipalName")]
        public string UserPrincipalName { get; set; }
        
    }
}

using Microsoft.Graph;
using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountApi.Azure
{
    public class Group
    {
        public Microsoft.Graph.Group GraphGroup;
        private IList<Microsoft.Graph.DirectoryObject> members = new List<Microsoft.Graph.DirectoryObject>();
        public IList<Microsoft.Graph.DirectoryObject> Members => members;

        public Group(Microsoft.Graph.Group group)
        {
            GraphGroup = group;
        }

        public Group(JObject obj)
        {
            GraphGroup = obj.ContainsKey("group") ? obj["group"].ToObject<Microsoft.Graph.Group>() : null;
            if (obj["members"] is JArray)
            {
                members = (obj["members"] as JArray).ToObject<List<Microsoft.Graph.DirectoryObject>>();
            }
        }

        public JObject ToJson()
        {
            return new JObject
            {
                ["group"] = JObject.FromObject(GraphGroup),
                ["members"] = JArray.FromObject(Members),
            };
        }

        internal async Task<bool> LoadMembers()
        {
            members.Clear();
            try
            {
                IGroupMembersCollectionWithReferencesPage page = null;

                while(true)
                {
                    if (page == null)
                    {
                        page = await Connector.Instance.Directory.Groups[GraphGroup.Id]
                            .Members
                            .Request()
                            .GetAsync();
                    }
                    else if (page.NextPageRequest != null)
                    {
                        page = await page.NextPageRequest.GetAsync();
                    }
                    else break;
                    foreach (var member in page)
                    {
                        members.Add(member);
                    }
                }

                //var result = await Connector.Instance.Directory.Groups[GraphGroup.Id]
                //.Members.Request()
                //.GetAsync();

                //foreach (var member in result)
                //{
                //    members.Add(member);
                //}
            }
            catch (Exception ex)
            {
                Connector.Instance.RegisterError(ex.Message);
                return false;
            }
            return true;
        }

        public bool HasMember(User user)
        {
            foreach(var member in members)
            {
                if (member.Id.Equals(user.Id)) return true;
            }
            return false;
        }

        public async Task<bool> AddMember(User user)
        {
            try
            {
                var directoryObject = new DirectoryObject
                {
                    Id = user.Id
                };

                await Connector.Instance.Directory.Groups[GraphGroup.Id].Members.References
                .Request()
                .AddAsync(directoryObject);

                await LoadMembers();
            }
            catch (Exception ex)
            {
                Connector.Instance.RegisterError(ex.Message);
                return false;
            }
            return true;
        }

        public async Task<bool> RemoveMember(User user)
        {
            try
            {

                await Connector.Instance.Directory.Groups[GraphGroup.Id].Members[user.Id].Reference
                .Request()
                .DeleteAsync();

                await LoadMembers();
            }
            catch (Exception ex)
            {
                Connector.Instance.RegisterError(ex.Message);
                return false;
            }
            return true;
        }

        public string Id => GraphGroup.Id;
        public string DisplayName => GraphGroup.DisplayName;

        public bool SecurityEnabled => GraphGroup.SecurityEnabled != null ? (bool)GraphGroup.SecurityEnabled : false;
    }
}

using AccountManager.Action.Group;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.State.Linked
{
    public class LinkedGroup
    {
        public GroupStatus<AccountApi.Wisa.ClassGroup> Wisa { get; } = new GroupStatus<AccountApi.Wisa.ClassGroup>();
        public GroupStatus<AccountApi.Directory.ClassGroup> Directory { get; } = new GroupStatus<AccountApi.Directory.ClassGroup>();
        public GroupStatus<AccountApi.Smartschool.Group> Smartschool { get; } = new GroupStatus<AccountApi.Smartschool.Group>();

        public List<GroupAction> Actions { get; } = new List<GroupAction>();

        public LinkedGroup(AccountApi.Wisa.ClassGroup group)
        {
            Wisa.Group = group;
        }

        public LinkedGroup(AccountApi.Directory.ClassGroup group)
        {
            Directory.Group = group;
        }

        public LinkedGroup(AccountApi.Smartschool.Group group)
        {
            Smartschool.Group = group;
        }

        public string Name
        {
            get
            {
                if (Wisa.Group != null) return Wisa.Group.Name;
                if (Directory.Group != null) return Directory.Group.Name;
                if (Smartschool.Group != null) return Smartschool.Group.Name;
                return "Group Name Error";
            }
        }

        public bool OK { get; set; }

        public void SetBasicFlags()
        {
            Wisa.SetFlag();
            Smartschool.SetFlag();
            Directory.SetFlag();
        }
    }
}

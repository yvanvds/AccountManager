using AccountApi;
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Utils
{
    public class TreeGroup
    {
        public ObservableCollection<object> Children { get; private set; }
        public IGroup Base;
        public string Header { get; set; } = "No Groups Found";
        public string Icon { get; set; } = "QuestionMarkBox";
        public int CountAccount { get; set; } = 0;

        public TreeGroup(IGroup Base)
        {
            this.Base = Base;
            Children = new ObservableCollection<object>();

            if (Base == null) return;

            Header = Base.Name;
            if (Base.Official)
            {
                Icon = "Class";
            }
            else
            {
                Icon = "UserGroup";
            }

            if (Base.Children != null)
            {
                foreach (var group in Base.Children)
                {
                    Children.Add(new TreeGroup(group));
                    CountAccount += (Children.Last() as TreeGroup).CountAccount;
                }

            }

            if (Base.Accounts != null)
            {
                foreach (var account in Base.Accounts)
                {
                    Children.Add(new TreeAccount(account));
                }
                CountAccount += Base.Accounts.Count;
            }
        }
    }
}

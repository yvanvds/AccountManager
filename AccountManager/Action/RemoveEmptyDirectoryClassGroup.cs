using AbstractAccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action
{
    class RemoveEmptyDirectoryClassGroup : IAction
    {
        public string Header => "Lege Active Directory Klas Verwijderen";

        public string Description => "Deze klas is leeg en bestaat enkel in Active Directory. " +
            "De klas kan verwijderd worden.";

        public bool CanBeApplied => true;

        public ObservableProperties.Prop<bool> InProgress { get; set; } = new ObservableProperties.Prop<bool>() { Value = false };

        public async Task Apply(LinkedGroup linkedGroup)
        {
            InProgress.Value = true;
            await Task.Delay(1000);
            InProgress.Value = false;
        }

        public RemoveEmptyDirectoryClassGroup(DirectoryApi.ClassGroup group)
        {
            this.group = group;
        }

        private DirectoryApi.ClassGroup group;
    }
}
